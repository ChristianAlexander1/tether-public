'use strict';

// Patch entry. Usage:
//   require('tether-shim-v2').install({ connect })       → Promise<{client, handshake}>
//   require('tether-shim-v2').beginSession({ connect })  → Promise<{client, handshake}>
//   require('tether-shim-v2').endSession()
//
// - connect() returns a duplex stream (net.Socket to the Unix socket in
//   production, an in-process pair in tests). Absent, connect to
//   process.env.TETHER_IPC_SOCK.
// - install() is idempotent: a second call returns the first promise and does
//   not open a second connection or a second handshake. It fits the
//   one-process-per-job lane (--require + TETHER_IPC_SOCK at spawn).
// - beginSession()/endSession() fit a persistent engine that runs many jobs in
//   one process against a fresh server socket per job: beginSession disposes
//   any live or in-flight session first, then connects and handshakes anew;
//   endSession detaches the patches and disposes the client without invoking
//   the fatal handler (deliberate teardown is not a connection loss).
// - On handshake success: patches require('tty') / require('child_process')
//   via Module._load interception, patches process.stdout/stderr/stdin TTY
//   properties, and wires signals/resize + the spawn domain.
// - There is no env-flag TTY faking: isTTY comes only from handshake.ttyFds.

const Module = require('node:module');
const net = require('node:net');

const { Client } = require('./ipc/client');
const ttyShim = require('./tty');
const cpShim = require('./child_process');
const signals = require('./signals');
const stdio = require('./stdio');
const workpath = require('./workpath');

let installPromise = null;
let state = null;
let originalLoad = null;
// Bumped by endSession()/beginSession() so a handshake that resolves after its
// session was superseded attaches nothing and disposes its own client.
let sessionGeneration = 0;

function defaultConnect() {
  const sockPath = process.env.TETHER_IPC_SOCK;
  if (!sockPath) {
    throw new Error(
      'tether-shim: TETHER_IPC_SOCK is not set and no connect() option was provided'
    );
  }
  return net.createConnection(sockPath);
}

/**
 * Keep the shim's own transport out of the host program's liveness accounting.
 *
 * A libuv-managed socket is "ref'd" by default, which keeps the event loop
 * alive for as long as it is open. The shim's connection lives for the whole
 * process, so leaving it ref'd means the loop is never empty: `beforeExit`
 * never fires, and any embedder that treats that event as "the script is
 * finished" waits forever. The shim must be invisible to the program it is
 * shimming, so the transport is unref'd. Requests still resolve normally —
 * unref only affects whether this handle can hold the process open by itself.
 */
function unref(stream) {
  if (stream && typeof stream.unref === 'function') {
    try { stream.unref(); } catch (_) { /* not a libuv handle; nothing to do */ }
  }
}

function patchModuleLoader() {
  if (originalLoad !== null) return; // already patched
  originalLoad = Module._load;
  function patchedLoad(request, parent, isMain) {
    if (request === 'tty' || request === 'node:tty') return ttyShim;
    if (request === 'child_process' || request === 'node:child_process') return cpShim;
    return originalLoad.apply(this, arguments);
  }
  // ESM imports of built-ins bypass Module._load. Split-graph launchers use
  // this link to copy the active TJIP implementations into Node's ESM export
  // cells via syncBuiltinESMExports(). Keep it pointed
  // at the genuinely native loader even when another Tether layer (for `os`)
  // sits immediately below this one.
  patchedLoad._tetherOriginalLoad =
    originalLoad._tetherOriginalLoad || originalLoad;
  patchedLoad._tetherPatched = true;
  Module._load = patchedLoad;
}

function unpatchModuleLoader() {
  if (originalLoad === null) return;
  Module._load = originalLoad;
  originalLoad = null;
}

function createSession(options = {}) {
  const generation = ++sessionGeneration;

  const connect = typeof options.connect === 'function' ? options.connect : defaultConnect;
  // The spawnSync second connection defaults to the same transport as the
  // main connection: the custom connect factory in tests, or a fresh Unix
  // socket connection to TETHER_IPC_SOCK in production (the spec's
  // two-connection design assumes the host accepts a second connection).
  const connectSync =
    typeof options.connectSync === 'function'
      ? options.connectSync
      : typeof options.connect === 'function'
        ? options.connect
        : defaultConnect;

  let stream;
  try {
    stream = connect();
  } catch (err) {
    const rejected = Promise.reject(err);
    rejected.catch(() => {}); // source-level guard; awaiters still see it
    return rejected;
  }

  const client = new Client(stream, { onFatal: options.onFatal });

  // Patch child_process before the handshake resolves so a `--require`'d
  // one-process-per-job script can spawnSync on the first tick. spawnSync
  // uses a dedicated second connection and only needs connectSync; TTY
  // truth is filled in when the handshake completes.
  patchModuleLoader();
  cpShim.attach({
    client: {
      on() {},
      request() {
        return Promise.reject(new Error('tether-shim: handshake pending'));
      },
    },
    handshake: { ttyFds: [], cols: 0, rows: 0, termName: 'dumb', colorTerm: '' },
    connectSync,
    addStream() {},
    removeStream() {},
    liveStreams() { return []; },
  });

  const promise = client
    .handshake({ proto: 2, role: 'node-shim', features: ['tty', 'spawn', 'flow'] })
    .then((handshake) => {
      // Unref only now, after the handshake round trip has completed. The
      // transport is not written to speculatively before this point on some
      // embedded libuv builds, unref'ing earlier can leave the connection's
      // own data event undelivered and the handshake promise hangs forever
      // (observed on nodejs-mobile; a host `net.Socket` does not show it,
      // which is why this needs a real device to catch — see
      // Packages/TermXNode HANDOFF for the reproduction).
      //
      // The shim's own handle must never keep the host program alive: once
      // we have what we need from it, it becomes invisible to `beforeExit`.
      unref(stream);
      if (generation !== sessionGeneration) {
        // endSession()/beginSession() ran while this handshake was in flight.
        try {
          client.dispose();
        } catch {
          /* ignore */
        }
        throw new Error('tether-shim: session superseded during handshake');
      }
      state = {
        client,
        handshake,
        connectSync,
        _streams: new Set(),
        addStream(s) {
          this._streams.add(s);
        },
        removeStream(s) {
          this._streams.delete(s);
        },
        liveStreams() {
          return [...this._streams];
        },
      };

      ttyShim.attach(state);
      signals.attach(state);
      stdio.attach(state);
      cpShim.attach(state);
      workpath.attach();
      patchModuleLoader();

      return { client, handshake };
    });
  promise.catch(() => {}); // avoid an unhandled rejection at the source
  return promise;
}

/**
 * Install the shim (once per process).
 * @param {object} [options]
 * @param {() => import('node:stream').Duplex} [options.connect]
 *        factory returning the IPC duplex stream. Called once for the main
 *        connection and (if no connectSync) again for each spawnSync job.
 * @param {() => import('node:stream').Duplex} [options.connectSync]
 *        optional dedicated factory for the spawnSync second connection.
 * @param {(reason: string) => void} [options.onFatal]
 *        override the fatal handler (default: one line on stderr + exit 1).
 * @returns {Promise<{client: Client, handshake: object}>}
 */
function install(options = {}) {
  if (installPromise) return installPromise; // idempotent
  installPromise = createSession(options);
  return installPromise;
}

/**
 * Open a fresh session, disposing any previous one first. This is the
 * persistent-engine entry point: one process, many jobs, a new server socket
 * per job. The fatal handler passed here should fail the *job*, not the
 * process (the default handler exits, which is only right when the process is
 * the job).
 * @returns {Promise<{client: Client, handshake: object}>}
 */
function beginSession(options = {}) {
  endSession();
  installPromise = createSession(options);
  return installPromise;
}

/**
 * Tear the active session down: unpatch the module loader, detach the tty /
 * child_process state, and dispose the client. Disposal never invokes the
 * fatal handler — deliberate teardown is not a connection loss. Idempotent;
 * also cancels a session whose handshake is still in flight.
 */
function endSession() {
  sessionGeneration += 1; // invalidate any in-flight handshake
  unpatchModuleLoader();
  if (state) {
    ttyShim.detach();
    stdio.detach();
    cpShim.detach();
    try {
      state.client.dispose();
    } catch {
      /* ignore */
    }
  }
  state = null;
  installPromise = null;
}

/** The install()/beginSession() promise (null when no session is active). */
function ready() {
  return installPromise;
}

/** Current shim state ({client, handshake, ...}) or null. Test/introspection aid. */
function getState() {
  return state;
}

/**
 * Test-only alias kept for existing suites; production code uses endSession().
 */
function _resetForTests() {
  endSession();
}

// --require support: when the host exports TETHER_IPC_SOCK, begin the
// handshake immediately so TTY truth is live as early as possible. This is
// the one-process-per-job lane; the persistent-engine lane has no socket at
// preload time and calls beginSession() per job from its job runner.
if (process.env.TETHER_IPC_SOCK) {
  install();
}

module.exports = {
  install,
  beginSession,
  endSession,
  ready,
  getState,
  _resetForTests,
  // Re-exported building blocks (usable without install()):
  Client,
  tty: ttyShim,
  childProcess: cpShim,
};
