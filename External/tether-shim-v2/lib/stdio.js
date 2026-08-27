'use strict';

// process.stdout / process.stderr / process.stdin patching.
//
// - isTTY on each of fd 0–2 comes exclusively from handshake.ttyFds.
// - TTY out-streams get columns/rows from the handshake, a getWindowSize(),
//   handshake-derived getColorDepth/hasColors, and are registered so
//   tty.resize updates them (with process.stdout/stderr included in the
//   "update all, then emit" ordering).
// - process.stdin gets a Node-shaped synchronous setRawMode() bridged over
//   the wire (optimistic local state + async reconciliation, see tty.js).
// - The underlying write paths of process.stdout/stderr are deliberately NOT
//   replaced: fd 1/2 writes still flow through the host's real descriptors,
//   so user code that replaces process.stdout.write (some CLIs do) cannot
//   break the shim.
//
// Note on flow-ack: flow.ack is per spawned pid (spawn domain). The child
// stdout/stderr ack logic lives in lib/child_process.js; the process-level
// streams above are host-owned fds and carry no wire flow control.

const ttyShim = require('./tty');

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

  const stdin = process.stdin;
  if (stdin) {
    const tty = isTty(0);
    defineProp(stdin, 'isTTY', tty);
    if (!('isRaw' in stdin) || stdin.isRaw === undefined) {
      stdin.isRaw = false;
    }
    // Node-shaped synchronous signature; wire reconciliation underneath.
    stdin.setRawMode = function setRawMode(mode) {
      return ttyShim.applyRawMode(this, 0, mode);
    };
  }
}

module.exports = { attach };
