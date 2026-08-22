'use strict';

/**
 * lib/ipc.js — the wire transport: request -> reply.
 *
 * Protocol (fixed, already spoken by the app):
 *   - one request  = one line of JSON terminated by '\n'
 *   - one reply    = one line of JSON terminated by '\n'
 *   - requests are synchronous: write exactly one request, read exactly one reply.
 *
 * All protocol handling lives behind roundTrip(requestObject) -> replyObject so
 * the transport can be swapped in tests (see setTransport / clearTransport).
 */

const fs = require('fs');
const net = require('net');

// A shared, single-instance SharedArrayBuffer used purely as a sleep primitive
// so we never block the thread with a busy loop when a non-blocking fd yields
// EAGAIN between frames.
const SLEEP = new Int32Array(new SharedArrayBuffer(4));
function sleep(ms) {
  Atomics.wait(SLEEP, 0, 0, ms > 0 ? ms : 0);
}

/** True when the process is attached to a terminal. */
function isInteractive() {
  return process.env.TERMX_INTERACTIVE === '1';
}

// ---------------------------------------------------------------------------
// Swappable transport.
// ---------------------------------------------------------------------------

let injected = null;
let envTransport = null;

/** Override the transport (used by tests to inject an in-process fake). */
function setTransport(fn) {
  injected = fn;
  resetEnvTransport();
}

/** Drop an injected transport so env-based resolution is used again. */
function clearTransport() {
  injected = null;
  resetEnvTransport();
}

function resetEnvTransport() {
  if (envTransport && typeof envTransport._reset === 'function') envTransport._reset();
  envTransport = null;
}

/**
 * Resolve the transport from (in order): an injected transport, then
 * TERMX_IPC_SOCKET, then TERMX_IPC_FD / TERMX_IPC_REPLY_FD. The env transport
 * is cached so a socket connection survives across roundTrips.
 */
function resolveTransport() {
  if (injected) return injected;
  if (!envTransport) envTransport = buildEnvTransport();
  return envTransport;
}

function buildEnvTransport() {
  const socket = process.env.TERMX_IPC_SOCKET;
  if (socket) return makeSocketTransport(socket);

  const inFd = process.env.TERMX_IPC_FD;
  const outFd = process.env.TERMX_IPC_REPLY_FD;
  if (inFd !== undefined && inFd !== '' && outFd !== undefined && outFd !== '') {
    return makeFdTransport(Number(inFd), Number(outFd));
  }

  throw new Error(
    'TermX: no IPC transport configured (set TERMX_IPC_SOCKET or TERMX_IPC_FD/TERMX_IPC_REPLY_FD)'
  );
}

/**
 * Connect the env transport. For a Unix socket this is the one asynchronous
 * step: establishing the connection (which requires the event loop to run) so
 * that every subsequent roundTrip can be purely synchronous. The app should
 * call this once during startup. For the fd transport / in-process fakes it is
 * a no-op and resolves immediately.
 */
function connect() {
  if (injected) return Promise.resolve();
  const t = resolveTransport();
  if (t && typeof t.connect === 'function') return t.connect();
  return Promise.resolve();
}

// ---------------------------------------------------------------------------
// Synchronous line reader over an fd (handles both blocking and non-blocking).
// ---------------------------------------------------------------------------

class SyncLineReader {
  constructor(fd) {
    this.fd = fd;
    this.pending = '';
    this.buf = Buffer.alloc(65536);
  }

  /** Returns the next '\n'-terminated line (without the '\n'), or null on EOF. */
  readLine() {
    for (;;) {
      const nl = this.pending.indexOf('\n');
      if (nl !== -1) {
        const line = this.pending.slice(0, nl);
        this.pending = this.pending.slice(nl + 1);
        return line;
      }
      let n;
      try {
        n = fs.readSync(this.fd, this.buf, 0, this.buf.length, null);
      } catch (err) {
        if (err && err.code === 'EAGAIN') {
          sleep(1);
          continue;
        }
        if (err && err.code === 'EOF') return null;
        throw err;
      }
      if (n === 0) return null; // EOF
      this.pending += this.buf.toString('utf8', 0, n);
    }
  }
}

function writeLine(fd, obj) {
  fs.writeSync(fd, JSON.stringify(obj) + '\n');
}

// ---------------------------------------------------------------------------
// fd transport: write requests to TERMX_IPC_FD, read replies from the reply fd.
// ---------------------------------------------------------------------------

function makeFdTransport(inFd, outFd) {
  const reader = new SyncLineReader(outFd);
  function fdTransport(request) {
    writeLine(inFd, request);
    const line = reader.readLine();
    if (line === null) throw new Error('TermX IPC: reply fd closed (EOF)');
    return JSON.parse(line);
  }
  fdTransport.connect = () => Promise.resolve();
  fdTransport.ready = () => true;
  fdTransport._reset = () => {};
  return fdTransport;
}

// ---------------------------------------------------------------------------
// socket transport: connect to a Unix domain socket, then do synchronous
// request/reply over the connected socket's fd.
// ---------------------------------------------------------------------------

function makeSocketTransport(socketPath) {
  let chan = null;
  let connectPromise = null;
  let socket = null;

  function connect() {
    if (chan) return Promise.resolve();
    if (connectPromise) return connectPromise;
    connectPromise = new Promise((resolve, reject) => {
      socket = new net.Socket();
      socket.once('connect', () => {
        const fd = socket._handle && socket._handle.fd;
        if (!fd) {
          socket.destroy();
          reject(new Error('TermX IPC: could not obtain socket fd for ' + socketPath));
          return;
        }
        chan = { fd, reader: new SyncLineReader(fd), socket };
        if (typeof socket.unref === 'function') socket.unref();
        resolve();
      });
      socket.once('error', (err) => {
        reject(new Error('TermX IPC: connect failed for ' + socketPath + ': ' + err.message));
      });
      socket.connect(socketPath);
    });
    return connectPromise;
  }

  function socketTransport(request) {
    if (!chan) {
      // Request arrived before connect() resolved. Kick off a connection for a
      // later call and tell the caller what to do (roundTrip is synchronous, so
      // we cannot wait for the async connect here).
      connect();
      throw new Error(
        'TermX IPC: socket ' + socketPath + ' not connected yet; await ipc.connect() before a synchronous request'
      );
    }
    writeLine(chan.fd, request);
    const line = chan.reader.readLine();
    if (line === null) throw new Error('TermX IPC: reply socket closed (EOF)');
    return JSON.parse(line);
  }

  socketTransport.connect = connect;
  socketTransport.ready = () => !!chan;
  socketTransport._reset = () => {
    if (socket) socket.destroy();
    chan = null;
    connectPromise = null;
    socket = null;
  };
  return socketTransport;
}

// ---------------------------------------------------------------------------
// roundTrip: send one request, return exactly one parsed reply.
// ---------------------------------------------------------------------------

function roundTrip(request) {
  const transport = resolveTransport();
  const reply = transport(request);
  if (!reply || typeof reply !== 'object') {
    throw new Error('TermX IPC: invalid (non-object) reply');
  }
  return reply;
}

module.exports = {
  roundTrip,
  connect,
  setTransport,
  clearTransport,
  resolveTransport,
  makeFdTransport,
  makeSocketTransport,
  isInteractive,
  _sleep: sleep,
};
