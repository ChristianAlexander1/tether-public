'use strict';

// TJIP/2 client: envelope handling, req/res correlation, evt dispatch,
// incoming-req answering (ENOSYS for unknown types), handshake, and a
// synchronous request/pump API used by the spawnSync two-connection design.

const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const { encodeFrame, FrameParser, protocolError } = require('./framing');

const PROTO = 2;
const FEATURES = ['tty', 'spawn', 'flow'];

// Sync-mode fd bridge (spawnSync's dedicated connection):
// A libuv-managed net.Socket never delivers bytes while we hold the thread,
// so in sync mode the client talks to the socket fd directly (POSIX: the
// kernel buffers both directions independently of the event loop). Between
// EAGAIN retries the thread parks on Atomics.wait — no deasync, no deps.
// Hosts that provide a genuinely blocking stream (read() returns data) need
// no bridge: stream.read() is always tried first.
const SYNC_FD_MAX_ATTEMPTS = 30000; // ~30 s of 1 ms parks before failing loud
const SYNC_FD_CHUNK = 65536;

/**
 * Default fatal handler: one line on fd 2 (written directly through fs so a
 * user-replaced process.stderr.write cannot swallow it), then exit(1).
 * Never hangs, never silently degrades.
 */
function defaultFatalHandler(reason) {
  try {
    fs.writeSync(2, `tether-shim: IPC connection lost (${reason})\n`);
  } catch {
    /* best effort */
  }
  process.exit(1);
}

class Client extends EventEmitter {
  /**
   * @param {import('node:stream').Duplex} stream duplex byte stream to the server
   * @param {object} [options]
   * @param {string} [options.role]   role advertised in `hello` (default "node-shim")
   * @param {boolean} [options.sync]  sync mode: no 'data'/'close' listeners are
   *                                  attached; the caller drives frames through
   *                                  pumpOnce()/requestSync() (spawnSync design)
   * @param {(reason: string) => void} [options.onFatal] override fatal action (tests)
   */
  constructor(stream, options = {}) {
    super();
    this.stream = stream;
    this.role = options.role || 'node-shim';
    this.sync = !!options.sync;
    this._onFatal = options.onFatal || defaultFatalHandler;
    this._nextId = 0;
    this._pending = new Map();
    this._reqHandlers = new Map();
    this._dead = false;
    this._parser = new FrameParser((env) => this._dispatch(env));
    this._fd = null; // sync-mode socket fd once detected
    this._pauseCell = new Int32Array(new SharedArrayBuffer(4)); // Atomics.wait park cell

    if (!this.sync) {
      this._onData = (chunk) => {
        try {
          this._parser.consume(chunk);
        } catch (err) {
          this.fatal(err.message);
        }
      };
      this._onStreamError = (err) => this.fatal(`stream error: ${err && err.message ? err.message : err}`);
      this._onClose = () => this.fatal('connection closed');
      stream.on('data', this._onData);
      stream.on('error', this._onStreamError);
      stream.on('close', this._onClose);
    }
  }

  get dead() {
    return this._dead;
  }

  // ---------------------------------------------------------------- envelope

  _dispatch(env) {
    if (env.kind === 'res') {
      const pending = this._pending.get(env.id);
      if (pending) {
        this._pending.delete(env.id);
        pending.resolve(env.body && typeof env.body === 'object' ? env.body : {});
      }
      // A res with no matching pending id is ignored (id already settled).
      return;
    }
    if (env.kind === 'req') {
      this._handleIncomingReq(env);
      return;
    }
    // kind === 'evt' (validated by the parser). Unknown evt types are ignored
    // by subscribers that do not listen; dispatch is name-based.
    const body = env.body && typeof env.body === 'object' ? env.body : {};
    this.emit('evt', env.type, body);
    this.emit(`evt:${env.type}`, body);
  }

  _handleIncomingReq(env) {
    const handler = this._reqHandlers.get(env.type);
    let result;
    try {
      result = handler
        ? handler(env.body && typeof env.body === 'object' ? env.body : {})
        : { ok: false, code: 'ENOSYS', message: `unknown request type: ${env.type}` };
    } catch (err) {
      result = { ok: false, code: err.code || 'EINVAL', message: err.message };
    }
    Promise.resolve(result).then(
      (body) => {
        if (body && body.ok === false && !body.code) {
          body = { ...body, code: 'EINVAL', message: body.message || 'request handler failed' };
        }
        this._safeSend({ v: PROTO, kind: 'res', id: env.id, type: env.type, body });
      },
      (err) => {
        this._safeSend({
          v: PROTO,
          kind: 'res',
          id: env.id,
          type: env.type,
          body: { ok: false, code: err.code || 'EINVAL', message: err.message },
        });
      }
    );
  }

  /** Register a handler for server-initiated requests of `type`. */
  onRequest(type, handler) {
    this._reqHandlers.set(type, handler);
  }

  // ------------------------------------------------------------------ sending

  _send(envelope) {
    if (this._dead) throw protocolError('cannot send: IPC client is dead');
    const frame = encodeFrame(envelope);
    // Sync mode on a real socket: write straight to the fd (libuv's write
    // queue would only flush on the event loop we are deliberately holding).
    if (this.sync && this._syncFdWrite(frame)) return;
    this.stream.write(frame);
  }

  /** Park the thread without burning CPU (best effort). */
  _pauseMs(ms) {
    try {
      Atomics.wait(this._pauseCell, 0, 0, ms);
    } catch {
      /* Atomics.wait unavailable: degrade to a spin between retries */
    }
  }

  /** Detect the underlying socket fd for sync-mode direct I/O (POSIX). */
  _syncFd() {
    if (this._fd !== null) return this._fd;
    const handle = this.stream && this.stream._handle;
    if (handle && Number.isInteger(handle.fd) && handle.fd >= 0) {
      this._fd = handle.fd;
    }
    return this._fd;
  }

  /** Write a full frame via direct fd writes. Returns false if no fd. */
  _syncFdWrite(frame) {
    const fd = this._syncFd();
    if (fd === null) return false;
    let offset = 0;
    while (offset < frame.length) {
      let written;
      try {
        written = fs.writeSync(fd, frame, offset, frame.length - offset);
      } catch (err) {
        if (err.code === 'EAGAIN' || err.code === 'EWOULDBLOCK') {
          this._pauseMs(1);
          continue;
        }
        if (err.code === 'EINTR') continue;
        throw err;
      }
      offset += written;
    }
    return true;
  }

  /**
   * Blocking read for sync mode: direct fd read, parking between EAGAIN
   * retries. Returns a Buffer of received bytes, or null when no fd is
   * available or the attempt budget is exhausted (caller fails loud).
   * EOF is fatal, as any mid-session connection loss is.
   */
  _blockingFdRead() {
    const fd = this._syncFd();
    if (fd === null) return null;
    const buf = Buffer.allocUnsafe(SYNC_FD_CHUNK);
    for (let attempt = 0; attempt < SYNC_FD_MAX_ATTEMPTS; attempt++) {
      let n;
      try {
        n = fs.readSync(fd, buf, 0, buf.length, null);
      } catch (err) {
        if (err.code === 'EAGAIN' || err.code === 'EWOULDBLOCK') {
          this._pauseMs(1);
          continue;
        }
        if (err.code === 'EINTR') continue;
        throw err;
      }
      if (n === 0) {
        this.fatal('connection closed during synchronous read');
        return null;
      }
      return Buffer.from(buf.subarray(0, n)); // copy: buf is reused
    }
    return null; // stalled; requestSync surfaces the EAGAIN diagnostics
  }

  _safeSend(envelope) {
    try {
      this._send(envelope);
    } catch {
      /* dead client: nothing more we can do */
    }
  }

  _allocId() {
    this._nextId += 1; // strictly increasing, starts at 1
    return this._nextId;
  }

  /** Send an evt envelope (no id). */
  send(type, body = {}) {
    this._send({ v: PROTO, kind: 'evt', type, body });
  }

  /**
   * Send a req envelope; resolves with res.body (which always has `ok`).
   * @returns {Promise<object>}
   */
  request(type, body = {}) {
    return new Promise((resolve, reject) => {
      if (this._dead) {
        reject(protocolError('IPC client is dead'));
        return;
      }
      const id = this._allocId();
      this._pending.set(id, { resolve, reject });
      try {
        this._send({ v: PROTO, kind: 'req', id, type, body });
      } catch (err) {
        this._pending.delete(id);
        reject(err);
      }
    });
  }

  /**
   * Blocking request: write the frame, then drive the stream with synchronous
   * reads until the response arrives. Only valid on a sync-mode client whose
   * stream supports synchronous read() (the dedicated spawnSync connection;
   * the host guarantees blocking reads there). Events seen while pumping are
   * dispatched to listeners as usual.
   * @returns {object} res.body
   */
  requestSync(type, body = {}) {
    if (this._dead) throw protocolError('IPC client is dead');
    const id = this._allocId();
    let settled = null;
    this._pending.set(id, {
      resolve: (b) => {
        settled = { body: b };
      },
      reject: (e) => {
        settled = { error: e };
      },
    });
    this._send({ v: PROTO, kind: 'req', id, type, body });
    while (settled === null) {
      if (!this.pumpOnce()) {
        this._pending.delete(id);
        throw protocolError(
          `sync request "${type}" stalled: no data available and no response ` +
            '(the sync connection must support blocking reads)'
        );
      }
    }
    if (settled.error) throw settled.error;
    return settled.body;
  }

  /**
   * Read whatever the stream can deliver synchronously and feed the parser.
   * @returns {boolean} true if any bytes were processed
   */
  pumpOnce() {
    const chunk = this.stream.read();
    if (chunk !== null && chunk !== undefined) {
      this._consumePumped(chunk);
      return true;
    }
    if (this.sync) {
      // Host-provided blocking streams answer read(); libuv sockets need the
      // direct-fd bridge instead.
      const fdChunk = this._blockingFdRead();
      if (fdChunk !== null) {
        this._consumePumped(fdChunk);
        return true;
      }
    }
    return false;
  }

  _consumePumped(chunk) {
    try {
      this._parser.consume(chunk);
    } catch (err) {
      // fatal() runs the fatal handler (default: stderr line + exit 1). If an
      // injected handler returns instead, surface the protocol error anyway.
      this.fatal(err.message);
      throw err;
    }
  }

  // ---------------------------------------------------------------- handshake

  /**
   * Client always speaks first. Resolves with the normalized handshake.
   * @param {object} [extra] extra hello body fields (e.g. role override)
   */
  handshake(extra = {}) {
    const reqBody = { proto: PROTO, role: this.role, features: FEATURES, ...extra };
    return this.request('hello', reqBody).then((res) => {
      if (!res || res.ok !== true) {
        throw protocolError(
          `handshake rejected: ${res && res.code ? res.code : 'unknown error'}`
        );
      }
      if (res.proto !== PROTO) {
        throw protocolError(`server advertised unsupported proto ${JSON.stringify(res.proto)}`);
      }
      return {
        proto: PROTO,
        features: Array.isArray(res.features) ? res.features.slice() : [],
        // ttyFds is the ONLY source of isTTY truth.
        ttyFds: Array.isArray(res.ttyFds) ? res.ttyFds.filter((fd) => Number.isInteger(fd) && fd >= 0) : [],
        cols: Number.isInteger(res.cols) ? res.cols : 80,
        rows: Number.isInteger(res.rows) ? res.rows : 24,
        termName: typeof res.termName === 'string' ? res.termName : 'xterm-256color',
        colorTerm: ['truecolor', '256', '16', 'none'].includes(res.colorTerm)
          ? res.colorTerm
          : 'none',
      };
    });
  }

  // -------------------------------------------------------------------- fatal

  /**
   * Fatal protocol/connection failure. Rejects all pending requests, emits
   * 'fatal' once, and invokes the fatal handler (default: one line on stderr
   * + exit 1). Idempotent.
   */
  fatal(reason) {
    if (this._dead) return;
    this._dead = true;
    const err = protocolError(`IPC connection lost (${reason})`);
    for (const [, p] of this._pending) p.reject(err);
    this._pending.clear();
    this.emit('fatal', err);
    this._onFatal(reason);
  }

  /** Detach stream listeners, mark dead, and release the transport. */
  dispose() {
    if (this._onData) this.stream.off('data', this._onData);
    if (this._onStreamError) this.stream.off('error', this._onStreamError);
    if (this._onClose) this.stream.off('close', this._onClose);
    this._dead = true;
    this._pending.clear();
    try {
      if (typeof this.stream.destroy === 'function') this.stream.destroy();
    } catch {
      /* transport already gone */
    }
  }
}

module.exports = { Client, defaultFatalHandler, PROTO, FEATURES };
