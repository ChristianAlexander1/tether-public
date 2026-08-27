'use strict';

// tty domain. All TTY truth derives from the TJIP/2 handshake (`ttyFds`,
// `cols`, `rows`, `colorTerm`). No environment flag can make a non-TTY look
// like a TTY here; env vars only influence color-depth overrides, exactly as
// in stock Node.

const { Readable, Writable } = require('node:stream');

let ctx = null; // set by install() after the handshake completes

function attach(context) {
  ctx = context;
}

function detach() {
  ctx = null;
}

function isTtyFd(fd) {
  if (!ctx) return false;
  return ctx.handshake.ttyFds.includes(fd);
}

/**
 * isatty(fd): true iff fd is in handshake.ttyFds.
 * Non-numeric, non-integer, negative, or unknown fds → false.
 * No env var may influence this.
 */
function isatty(fd) {
  if (typeof fd !== 'number' || !Number.isInteger(fd) || fd < 0) return false;
  return isTtyFd(fd);
}

// ------------------------------------------------------------ color decision

// Node's real priority order, applied to the handshake colorTerm:
//   1. FORCE_COLOR: 0→1, 1→4, 2→8, 3→24 (''/'true' behave like 1 per Node)
//   2. NO_COLOR / NODE_DISABLE_COLORS defined → 1
//   3. stdout is not a TTY → 1
//   4. TERM === 'dumb' → 1
//   5. handshake colorTerm: truecolor→24, 256→8, 16→4, none→1
const FORCE_COLOR_DEPTH = { 0: 1, 1: 4, 2: 8, 3: 24 };
const COLOR_TERM_DEPTH = { truecolor: 24, 256: 8, 16: 4, none: 1 };

function colorDepthForFd(fd, env) {
  if (!ctx) return 1;
  const force = env.FORCE_COLOR;
  if (force !== undefined) {
    if (force === '' || force === 'true') return 4; // Node: bare FORCE_COLOR means "some color"
    if (Object.prototype.hasOwnProperty.call(FORCE_COLOR_DEPTH, force)) {
      return FORCE_COLOR_DEPTH[force];
    }
    return 1; // unrecognized FORCE_COLOR value disables color, like Node's default branch
  }
  if (env.NO_COLOR !== undefined) return 1;
  if (env.NODE_DISABLE_COLORS !== undefined) return 1;
  if (!isatty(fd)) return 1;
  if (env.TERM === 'dumb') return 1;
  const depth = COLOR_TERM_DEPTH[ctx.handshake.colorTerm];
  return depth === undefined ? 1 : depth;
}

/** Color depth for stdout, Node's getColorDepth(env) contract. */
function getColorDepth(env = process.env) {
  return colorDepthForFd(1, env || {});
}

/** hasColors(count, env) consistent with getColorDepth: 2**depth >= count. */
function hasColors(count = 16, env = process.env) {
  if (typeof count === 'object' && count !== null) {
    env = count;
    count = 16;
  }
  return 2 ** getColorDepth(env) >= count;
}

// ---------------------------------------------------------------- raw bridge

function errWithCode(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

/**
 * Node's setRawMode signature is synchronous, but tty.setRawMode on the wire
 * is a req/res round trip. Bridge:
 *   - fd is not a TTY per the handshake → throw EINVAL synchronously (same
 *     error shape Node throws), no request sent.
 *   - otherwise update local `isRaw` optimistically, send the request, return
 *     `this` immediately.
 *   - async reconciliation: if the server rejects the request, roll `isRaw`
 *     back and emit 'error' (err.code from the reply) on the stream.
 */
function applyRawMode(stream, fd, mode) {
  if (!isatty(fd)) {
    // Same shape Node throws for setRawMode on a non-TTY.
    throw errWithCode('EINVAL', 'setRawMode is not supported on a non-tty process');
  }
  const boolMode = !!mode;
  const previous = !!stream.isRaw;
  stream.isRaw = boolMode; // optimistic local state
  ctx.client
    .request('tty.setRawMode', { fd, mode: boolMode })
    .then((res) => {
      if (!res.ok) {
        stream.isRaw = previous; // reconciliation failure: roll back
        const err = errWithCode(res.code || 'EINVAL', res.message || 'tty.setRawMode failed');
        stream.emit('error', err);
      } else if (typeof res.wasRaw === 'boolean') {
        // Server confirms; `wasRaw` tells us the prior server-side state.
        // Local truth is the mode we asked for.
        stream.isRaw = boolMode;
      }
    })
    .catch((err) => {
      stream.isRaw = previous;
      stream.emit('error', err);
    });
  return stream;
}

// ------------------------------------------------------------------- streams

class ReadStream extends Readable {
  /**
   * @param {number} fd file descriptor this stream stands for
   */
  constructor(fd, options) {
    super(options);
    this.fd = fd;
    this.isTTY = isatty(fd);
    this.isRaw = false;
  }

  setRawMode(mode) {
    return applyRawMode(this, this.fd, mode);
  }

  _read() {
    // Input bytes for fd 0 are fed by the host through the real descriptor;
    // this class carries TTY identity and raw-mode control over the wire.
  }
}

class WriteStream extends Writable {
  constructor(fd, options) {
    super(options);
    this.fd = fd;
    this.isTTY = isatty(fd);
    this.columns = ctx ? ctx.handshake.cols : 80;
    this.rows = ctx ? ctx.handshake.rows : 24;
    if (this.isTTY && ctx) {
      ctx.addStream(this);
      this.on('close', () => ctx.removeStream(this));
    }
  }

  getWindowSize() {
    return [this.columns, this.rows];
  }

  getColorDepth(env = process.env) {
    return colorDepthForFd(this.fd, env || {});
  }

  hasColors(count = 16, env = process.env) {
    return 2 ** this.getColorDepth(env) >= count;
  }

  _write(chunk, encoding, callback) {
    callback();
  }
}

module.exports = {
  isatty,
  ReadStream,
  WriteStream,
  getColorDepth,
  hasColors,
  // internal wiring used by lib/index.js and lib/stdio.js
  attach,
  detach,
  applyRawMode,
  colorDepthForFd,
};
