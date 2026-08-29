'use strict';

// process.stdout / process.stderr / process.stdin patching.
//
// - isTTY on each of fd 0–2 comes exclusively from handshake.ttyFds.
// - TTY out-streams get columns/rows from the handshake, a getWindowSize(),
//   handshake-derived getColorDepth/hasColors, and are registered so
//   tty.resize updates them (with process.stdout/stderr included in the
//   "update all, then emit" ordering).
// - process.stdin: when fd 0 is a TTY, we install a Readable and write
//   pushed `tty.stdin` frames into it. nodejs-mobile cannot poll a borrowed
//   PTY slave after npm, so the host drains the slave and forwards bytes
//   over the wire — the same push model as tty.resize. The Readable is
//   never ended on idle: a terminal does not imply stdin EOF.
// - process.stdin.setRawMode is Node-shaped (optimistic local state +
//   async reconciliation, see tty.js).
// - The underlying write paths of process.stdout/stderr are deliberately NOT
//   replaced: fd 1/2 writes still flow through the host's real descriptors,
//   so user code that replaces process.stdout.write (some CLIs do) cannot
//   break the shim.
//
// Note on flow-ack: flow.ack is per spawned pid (spawn domain). The child
// stdout/stderr ack logic lives in lib/child_process.js; the process-level
// streams above are host-owned fds and carry no wire flow control.

const ttyShim = require('./tty');

let installedStdin = null;
let savedStdin = null;
let stdinEnded = false;

function defineProp(obj, name, value) {
  try {
    Object.defineProperty(obj, name, {
      value,
      writable: true,
      configurable: true,
      enumerable: true,
    });
    return true;
  } catch {
    return false;
  }
}

function replaceProcessStdin(stream) {
  savedStdin = process.stdin;
  installedStdin = stream;
  try {
    Object.defineProperty(process, 'stdin', {
      configurable: true,
      enumerable: true,
      get() {
        return stream;
      },
      set() {
        /* ignore replacements that would drop the live channel */
      },
    });
  } catch {
    try {
      process.stdin = stream;
    } catch {
      /* leave native stdin */
    }
  }
}

function installLiveStdin(context) {
  stdinEnded = false;
  const stdin = new ttyShim.ReadStream(0);
  // High water mark large enough for a 10 KB paste without dropping keys.
  // Data arrives from IPC, not from _read, so _read stays a no-op wait.
  stdin.setRawMode = function setRawMode(mode) {
    return ttyShim.applyRawMode(this, 0, mode);
  };

  context.client.on('evt:tty.stdin', (body) => {
    if (stdinEnded) return;
    const b64 = body && body.dataB64;
    if (typeof b64 !== 'string' || b64.length === 0) {
      // Empty is not EOF. Idle terminals keep stdin open forever.
      return;
    }
    let buf;
    try {
      buf = Buffer.from(b64, 'base64');
    } catch {
      return;
    }
    if (!buf.length) return;
    try {
      stdin.push(buf);
    } catch {
      /* stream already destroyed during teardown */
    }
  });

  replaceProcessStdin(stdin);
  defineProp(stdin, 'isTTY', true);
  if (!('isRaw' in stdin) || stdin.isRaw === undefined) {
    stdin.isRaw = false;
  }
  context.liveStdin = stdin;
}

function attach(context) {
  const hs = context.handshake;
  const isTty = (fd) => hs.ttyFds.includes(fd);

  for (const entry of [
    [process.stdout, 1],
    [process.stderr, 2],
  ]) {
    const stream = entry[0];
    const fd = entry[1];
    if (!stream) continue;

    const tty = isTty(fd);
    defineProp(stream, 'isTTY', tty);
    if (tty) {
      stream.columns = hs.cols;
      stream.rows = hs.rows;
      if (typeof stream.getWindowSize !== 'function') {
        stream.getWindowSize = function getWindowSize() {
          return [this.columns, this.rows];
        };
      }
      // getColorDepth/hasColors now answer from the handshake colorTerm.
      stream.getColorDepth = function getColorDepth(env = process.env) {
        return ttyShim.colorDepthForFd(fd, env || {});
      };
      stream.hasColors = function hasColors(count = 16, env = process.env) {
        return 2 ** this.getColorDepth(env) >= count;
      };
      context.addStream(stream); // participates in resize fan-out
    }
  }

  if (isTty(0)) {
    installLiveStdin(context);
    return;
  }

  const stdin = process.stdin;
  if (stdin) {
    defineProp(stdin, 'isTTY', false);
    if (!('isRaw' in stdin) || stdin.isRaw === undefined) {
      stdin.isRaw = false;
    }
    stdin.setRawMode = function setRawMode(mode) {
      return ttyShim.applyRawMode(this, 0, mode);
    };
  }
}

function detach() {
  stdinEnded = true;
  if (installedStdin) {
    try {
      installedStdin.removeAllListeners();
    } catch {
      /* ignore */
    }
    // Destroy without pushing null first: teardown is not stdin EOF for a
    // still-open terminal; the process is leaving, the stream just goes away.
    try {
      installedStdin.destroy();
    } catch {
      /* ignore */
    }
    installedStdin = null;
  }
  if (savedStdin) {
    try {
      Object.defineProperty(process, 'stdin', {
        value: savedStdin,
        configurable: true,
        enumerable: true,
        writable: true,
      });
    } catch {
      try {
        process.stdin = savedStdin;
      } catch {
        /* ignore */
      }
    }
    savedStdin = null;
  }
}

module.exports = { attach, detach };
