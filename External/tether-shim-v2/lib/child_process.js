'use strict';

// child_process over the TJIP/2 spawn domain.
//
// - spawn() returns a ChildProcess synchronously (Node semantics); `pid` is
//   filled in when spawn.start replies; 'spawn' fires after that.
// - stdout/stderr are Readables fed from spawn.stdout/spawn.stderr events
//   (base64-decoded). flow.ack is sent only after a chunk has been consumed
//   out of the stream, so the server's 256 KiB in-flight window is honored
//   even when the consumer is slow.
// - stdin is a Writable honoring the `window` reported by spawn.stdin
//   responses: at window <= 0 data is queued and write() returns false; a
//   later response reporting window > 0 flushes the queue in order and
//   emits 'drain' exactly once.
// - Event order: 'spawn' → 'exit'(code, signal) → readables end → 'close'
//   after BOTH readables emitted 'end'.
// - ENOENT from spawn.start → 'error' once, never 'exit'/'close' (matches
//   real Node).
// - spawnSync runs the whole job request-by-request over a SECOND connection
//   (role "node-shim-sync"), driven by synchronous reads. See HANDOFF.md.

const { EventEmitter } = require('node:events');
const { Readable, Writable } = require('node:stream');
const realChildProcess = require('node:child_process');

const { Client, FEATURES, PROTO } = require('./ipc/client');
const ttyShim = require('./tty');

const RAW_CHUNK_MAX = 65536; // raw chunk <= 64 KiB before base64
const DEFAULT_MAX_BUFFER = 1024 * 1024; // exec/execFile default: 1 MB
// The wire spec mandates the shell argv for exec(): ["/bin/sh", "-c", command].
// This is a spec constant (overridable via options.shell), not a hardcoded
// program special-case.
const DEFAULT_SHELL = '/bin/sh';

let ctx = null;
const childrenByPid = new Map();
// Events can arrive before the spawn.start response is processed (a fast
// producer races the round trip). Buffer them per pid and replay in arrival
// order once the child is registered.
const earlyEvents = new Map(); // pid → [{ kind: 'stdout'|'stderr'|'exit', body }]

function errWithCode(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

function attach(context) {
  ctx = context;
  const client = context.client;

  client.on('evt:spawn.stdout', (body) => routeOutput(body, 'stdout'));
  client.on('evt:spawn.stderr', (body) => routeOutput(body, 'stderr'));
  client.on('evt:spawn.exit', (body) => {
    const child = childrenByPid.get(body.pid);
    if (!child) {
      bufferEarly(body.pid, { kind: 'exit', body });
      return;
    }
    childrenByPid.delete(body.pid);
    const code = body.code === undefined ? null : body.code;
    const signal = body.signal === undefined ? null : body.signal;
    child._onExit(code, signal);
  });
}

function detach() {
  ctx = null;
  childrenByPid.clear();
  earlyEvents.clear();
}

// Safety cap: events for a pid that never registers (a producer racing a
// failed spawn, or a misbehaving server) must not grow memory without bound.
const EARLY_EVENTS_CAP_PER_PID = 4096;
const EARLY_EVENTS_CAP_PIDS = 1024;

function bufferEarly(pid, entry) {
  let list = earlyEvents.get(pid);
  if (!list) {
    if (earlyEvents.size >= EARLY_EVENTS_CAP_PIDS) return; // drop: pathological
    list = [];
    earlyEvents.set(pid, list);
  }
  if (list.length >= EARLY_EVENTS_CAP_PER_PID) return; // drop: pathological
  list.push(entry);
}

function drainEarlyEvents(child) {
  const list = earlyEvents.get(child.pid);
  if (!list) return;
  earlyEvents.delete(child.pid);
  for (const entry of list) {
    if (entry.kind === 'exit') {
      childrenByPid.delete(child.pid);
      const code = entry.body.code === undefined ? null : entry.body.code;
      const signal = entry.body.signal === undefined ? null : entry.body.signal;
      child._onExit(code, signal);
    } else {
      deliverOutput(child, entry.kind, entry.body);
    }
  }
}

function routeOutput(body, kind) {
  const child = childrenByPid.get(body.pid);
  if (!child) {
    bufferEarly(body.pid, { kind, body });
    return;
  }
  deliverOutput(child, kind, body);
}

function deliverOutput(child, kind, body) {
  const stream = kind === 'stdout' ? child.stdout : child.stderr;
  if (typeof body.dataB64 === 'string' && body.dataB64.length > 0) {
    stream._offer(Buffer.from(body.dataB64, 'base64'));
  }
  child._noteIo();
}

// ------------------------------------------------------------------ readable

/**
 * Readable fed by spawn.stdout/spawn.stderr events with per-chunk flow.ack.
 *
 * Delivery accounting: a chunk is pushed into Node's buffer one at a time
 * (`_inflight`); when _read() runs again the previously pushed chunk has been
 * consumed, so it is acked then. That means the unacked set (internal queue
 * + Node's buffer) never exceeds what the server may keep in flight, i.e.
 * the 256 KiB window — memory stays bounded with a slow/paused consumer.
 */
class ShimReadable extends Readable {
  constructor(child) {
    super({ highWaterMark: RAW_CHUNK_MAX });
    this._child = child;
    this._queue = []; // received, not yet pushed (unacked)
    this._queuedBytes = 0;
    this._inflight = null; // pushed into Node's buffer, not yet acked
    this._remoteEnded = false;
    this._pushedNull = false;
  }

  /** Offer a decoded chunk from the wire. */
  _offer(buf) {
    if (this._remoteEnded || this._pushedNull || this.destroyed) return;
    this._queue.push(buf);
    this._queuedBytes += buf.length;
    this._kick();
  }

  _kick() {
    if (this.destroyed || this._pushedNull) return;
    // One chunk at a time. No high-water-mark gate here: refusing to push
    // after Node called _read() would leave the stream stuck in "reading"
    // state forever (Readable contract: _read must eventually push).
    // Memory stays bounded anyway because the total unacked set (queue +
    // Node's buffer) can never exceed the server's flow window.
    if (this._inflight === null && this._queue.length > 0) {
      const buf = this._queue.shift();
      this._queuedBytes -= buf.length;
      this._inflight = buf;
      this.push(buf);
    }
    if (this._remoteEnded && this._queue.length === 0 && this._inflight === null) {
      this._pushedNull = true;
      this.push(null);
    }
  }

  _read() {
    // Node is asking for more: whatever was pushed before has been consumed.
    if (this._inflight !== null) {
      this._ackBytes(this._inflight.length);
      this._inflight = null;
    }
    this._kick();
  }

  _ackBytes(bytes) {
    if (!ctx || this._child.pid === undefined || ctx.client.dead) return;
    try {
      ctx.client.send('flow.ack', { pid: this._child.pid, bytes });
    } catch {
      /* client dying; fatal path handles it */
    }
  }

  /** Server said the process exited: EOF once buffered data is consumed. */
  _endRemote() {
    if (this._pushedNull || this.destroyed) return;
    this._remoteEnded = true;
    this._kick();
  }

  /** Bytes held on behalf of the wire (queue + Node's buffer). Unacked set. */
  _tetherBuffered() {
    return this._queuedBytes + this.readableLength;
  }
}

// ------------------------------------------------------------------ writable

/**
 * stdin Writable honoring the server-reported window.
 *
 * Window <= 0: writes are queued, write() returns false, and a single retry
 * probe is sent after the next observable activity for the pid (output event
 * or exit); the response reports the current window. If window > 0 the queue
 * flushes in order and 'drain' is emitted exactly once.
 */
class ShimWritable extends Writable {
  constructor(child) {
    super({ autoDestroy: false, highWaterMark: 64 * 1024 });
    this._child = child;
    this._queue = []; // { buf, cb }
    this._queueBytes = 0;
    this._inflight = null; // { buf, cb } currently awaiting a spawn.stdin res
    this._window = Number.POSITIVE_INFINITY; // unknown until first response
    this._drainArmed = false;
    this._endPending = null; // callback for end()
    this._stdinEnded = false;
    this._destroyErr = null;
    // Window only refreshes in spawn.stdin responses, so when it drops to 0
    // the queue is retried with a single probe request whenever the server
    // shows activity for this pid (output events / exit). The response
    // reports the current window; if it is still <= 0 we re-buffer.
    child.on('_io', () => this._pump(true));
  }

  write(chunk, encoding, callback) {
    if (typeof encoding === 'function') {
      callback = encoding;
      encoding = 'utf8';
    }
    const cb = typeof callback === 'function' ? callback : () => {};

    if (this.destroyed || this._child._exited || this._child._spawnFailed) {
      const err = this._destroyErr || errWithCode('EPIPE', 'write to closed child stdin');
      process.nextTick(() => cb(err));
      return false;
    }

    const buf = Buffer.isBuffer(chunk)
      ? chunk
      : Buffer.from(chunk === undefined || chunk === null ? '' : String(chunk), encoding || 'utf8');

    // Pre-split into raw chunks <= 64 KiB; the user's callback rides the last piece.
    if (buf.length === 0) {
      process.nextTick(() => cb(null));
      return this._window > 0 && this._queueBytes <= this.writableHighWaterMark;
    }
    let offset = 0;
    while (offset < buf.length) {
      const part = buf.subarray(offset, offset + RAW_CHUNK_MAX);
      offset += part.length;
      const isLast = offset >= buf.length;
      this._queue.push({ buf: Buffer.from(part), cb: isLast ? cb : null });
    }
    this._queueBytes += buf.length;
    this._pump();
    return this._window > 0 && this._queueBytes <= this.writableHighWaterMark;
  }

  _pump(isProbe = false) {
    const child = this._child;
    const canSend = this._window > 0 || isProbe;
    if (
      this.destroyed ||
      this._inflight !== null ||
      this._queue.length === 0 ||
      !canSend ||
      child.pid === undefined ||
      child._exited ||
      child._spawnFailed ||
      !ctx
    ) {
      if (!canSend && this._queue.length > 0) this._drainArmed = true;
      this._maybeFinishEnd();
      return;
    }

    const item = this._queue.shift();
    this._queueBytes -= item.buf.length;
    this._inflight = item;

    ctx.client
      .request('spawn.stdin', { pid: child.pid, dataB64: item.buf.toString('base64') })
      .then((res) => {
        this._inflight = null;
        if (this.destroyed) {
          // Exited/destroyed while the request was in flight: EPIPE for the writer.
          if (item.cb) item.cb(this._destroyErr || errWithCode('EPIPE', 'child stdin closed'));
          return;
        }
        if (!res.ok) {
          const err = errWithCode(res.code || 'EPIPE', res.message || 'spawn.stdin failed');
          if (item.cb) item.cb(err);
          this._failQueue(err);
          return;
        }
        if (item.cb) item.cb(null);
        if (Number.isInteger(res.window)) this._window = res.window;
        if (this._window > 0 && this._drainArmed) {
          this._drainArmed = false;
          this.emit('drain'); // exactly once per stall
        } else if (this._window <= 0) {
          this._drainArmed = this._queue.length > 0;
        }
        this._pump();
        this._maybeFinishEnd(); // an end() may be waiting on the last write
      })
      .catch((err) => {
        this._inflight = null;
        if (item.cb) item.cb(err);
      });
  }

  end(chunk, encoding, callback) {
    if (typeof chunk === 'function') {
      callback = chunk;
      chunk = null;
    } else if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    const cb = typeof callback === 'function' ? callback : () => {};
    if (chunk !== null && chunk !== undefined) {
      this.write(chunk, encoding);
    }
    this._endPending = cb;
    this._pump();
    this._maybeFinishEnd();
    return this;
  }

  _maybeFinishEnd() {
    if (
      this._endPending === null ||
      this._stdinEnded ||
      this._queue.length > 0 ||
      this._inflight !== null
    ) {
      return;
    }
    const child = this._child;
    const cb = this._endPending;
    this._endPending = null;
    if (child._exited || child._spawnFailed || !ctx || child.pid === undefined) {
      process.nextTick(() =>
        cb(this._destroyErr || errWithCode('EPIPE', 'child exited before stdin was flushed'))
      );
      return;
    }
    this._stdinEnded = true;
    ctx.client
      .request('spawn.stdinEnd', { pid: child.pid })
      .then((res) => {
        if (res.ok) cb(null);
        else cb(errWithCode(res.code || 'EPIPE', res.message || 'spawn.stdinEnd failed'));
      })
      .catch((err) => cb(err));
  }

  _failQueue(err) {
    for (const item of this._queue) {
      if (item.cb) item.cb(err);
    }
    this._queue = [];
    this._queueBytes = 0;
  }

  _destroy(err, callback) {
    this._destroyErr = err || this._destroyErr || errWithCode('EPIPE', 'child stdin destroyed');
    this._failQueue(this._destroyErr);
    if (this._inflight && this._inflight.cb) {
      this._inflight.cb(this._destroyErr);
    }
    this._inflight = null;
    if (this._endPending) {
      const cb = this._endPending;
      this._endPending = null;
      process.nextTick(() => cb(this._destroyErr));
    }
    // Pass the original err through so destroy(err) surfaces an 'error'
    // event (Node only emits it when the _destroy callback receives it).
    callback(err || undefined);
  }
}

// ------------------------------------------------------------- child process

class ChildProcess extends EventEmitter {
  constructor() {
    super();
    this.pid = undefined;
    this.exitCode = null;
    this.signalCode = null;
    this.killed = false;
    this.connected = false;
    this._exited = false;
    this._spawnFailed = false;
    this._exitArgs = null;
    this._streamsEnded = 0;
    this._closeEmitted = false;

    this.stdin = new ShimWritable(this);
    this.stdout = new ShimReadable(this);
    this.stderr = new ShimReadable(this);
    this.stdio = [this.stdin, this.stdout, this.stderr];

    this.stdout.on('end', () => this._noteStreamEnd());
    this.stderr.on('end', () => this._noteStreamEnd());
  }

  /** Internal: server activity observed for this pid (retry stdin probes). */
  _noteIo() {
    this.emit('_io');
  }

  _noteStreamEnd() {
    this._streamsEnded += 1;
    if (this._streamsEnded === 2 && this._exitArgs !== null) {
      // Deferred so 'close' lands after every stream 'end' listener has run.
      process.nextTick(() => {
        if (!this._closeEmitted) {
          this._closeEmitted = true;
          this.emit('close', this._exitArgs[0], this._exitArgs[1]);
        }
      });
    }
  }

  _onExit(code, signal) {
    if (this._exited) return; // exactly one spawn.exit per pid
    this._exited = true;
    this.exitCode = code;
    this.signalCode = signal;
    this._exitArgs = [code, signal];

    process.nextTick(() => {
      this.emit('exit', code, signal);

      // End the readables (EOF once buffered data is consumed).
      this.stdout._endRemote();
      this.stderr._endRemote();

      // stdin: pending writes error with EPIPE and the writable is destroyed.
      // With nothing pending, destroy silently (normal-exit path must not
      // raise an 'error' event on an unused stdin).
      if (!this.stdin.destroyed) {
        const hasPending =
          this.stdin._queue.length > 0 ||
          this.stdin._inflight !== null ||
          this.stdin._endPending !== null;
        if (hasPending) {
          this.stdin.destroy(errWithCode('EPIPE', 'child process exited before stdin was flushed'));
        } else {
          this.stdin.destroy();
        }
      }
    });
  }

  _onSpawnError(code, message, command, args) {
    if (this._spawnFailed || this._exited) return;
    this._spawnFailed = true;
    const err = errWithCode(code, message);
    err.syscall = `spawn ${command}`;
    err.path = command;
    err.spawnargs = args.slice();
    process.nextTick(() => {
      this.emit('error', err);
      // Streams never carry data; no 'exit'/'close' (matches real Node).
      this.stdout._endRemote();
      this.stderr._endRemote();
      if (!this.stdin.destroyed) this.stdin.destroy();
    });
  }

  /**
   * kill(signal='SIGTERM') → spawn.kill.
   * Returns true when the request was sent (pid known, not yet exited);
   * false when there is nothing to signal (mirrors Node's false for a dead
   * child). An ESRCH reply is swallowed: by the time the server answers, the
   * process is already gone, which Node callers observe as a no-op.
   */
  kill(signal = 'SIGTERM') {
    if (this.pid === undefined || this._exited || this._spawnFailed || !ctx) return false;
    const sig = typeof signal === 'number' || typeof signal === 'string' ? String(signal) : 'SIGTERM';
    ctx.client
      .request('spawn.kill', { pid: this.pid, signal: sig })
      .then((res) => {
        if (!res.ok && res.code === 'ESRCH') return; // already gone: no-op
        // Other failures are reported asynchronously on the child.
        if (!res.ok) this.emit('error', errWithCode(res.code, res.message || 'spawn.kill failed'));
      })
      .catch(() => {
        /* connection-level failures go through the fatal path */
      });
    this.killed = true;
    return true;
  }

  /**
   * TJIP children share the session transport rather than owning an individual
   * libuv process handle. The transport is already unref'd by the session shim,
   * so these standard Node methods are intentionally chainable no-ops. Desktop
   * opener packages call unref() after a detached spawn and must not crash.
   */
  ref() {
    return this;
  }

  unref() {
    return this;
  }

  /**
   * spawn.resize → promise of the response body. Rejects/resolves with
   * { ok:false, code:'EINVAL' } unless the child was started with pty:true.
   */
  resize(cols, rows) {
    if (this.pid === undefined || !ctx) {
      return Promise.reject(errWithCode('ESRCH', 'child has no pid'));
    }
    return ctx.client.request('spawn.resize', { pid: this.pid, cols, rows });
  }
}

// ------------------------------------------------------------------- helpers

function normalizeStdio(stdio) {
  if (stdio === undefined || stdio === null) return ['pipe', 'pipe', 'pipe'];
  if (typeof stdio === 'string') return [stdio, stdio, stdio];
  if (!Array.isArray(stdio)) return ['pipe', 'pipe', 'pipe'];
  const arr = stdio.slice(0, 3).map((entry) => (entry === null || entry === undefined ? 'pipe' : String(entry)));
  while (arr.length < 3) arr.push('pipe');
  return arr;
}

function normalizeArgs(args, options) {
  let opts = options;
  let argList = args;
  if (!Array.isArray(argList) && argList && typeof argList === 'object' && opts === undefined) {
    opts = argList;
    argList = [];
  }
  return { args: Array.isArray(argList) ? argList : [], options: opts || {} };
}

// --------------------------------------------------------------------- spawn

function spawn(command, args, options) {
  const norm = normalizeArgs(args, options);
  const opts = norm.options;
  const child = new ChildProcess();

  const argv = [String(command), ...norm.args.map(String)];
  const stdio = normalizeStdio(opts.stdio);
  // pty:true when the caller asked to inherit stdio and fd 0 is genuinely a
  // PTY per the handshake — never from an env flag.
  const pty = opts.stdio === 'inherit' && ttyShim.isatty(0);

  const body = {
    argv,
    cwd: opts.cwd || process.cwd(),
    env: opts.env || process.env,
    stdio,
    pty,
  };

  process.nextTick(() => {
    if (!ctx) {
      child._onSpawnError('ENOSYS', 'tether-shim is not installed', argv[0], norm.args);
      return;
    }
    ctx.client
      .request('spawn.start', body)
      .then((res) => {
        if (res.ok && Number.isInteger(res.pid)) {
          child.pid = res.pid;
          childrenByPid.set(res.pid, child);
          child.connected = true;
          process.nextTick(() => {
            // Node ordering: 'spawn' first, then any queued I/O/exit events.
            if (!child._exited && !child._spawnFailed) child.emit('spawn');
            child.stdin._pump(); // flush writes queued before the pid arrived
            drainEarlyEvents(child);
          });
        } else {
          child._onSpawnError(res.code || 'EINVAL', res.message || 'spawn.start failed', argv[0], norm.args);
        }
      })
      .catch((err) => {
        child._onSpawnError(err.code || 'EPROTO', err.message, argv[0], norm.args);
      });
  });

  return child;
}

// ------------------------------------------------------------------ exec-ish

function bufferChild(child, maxBuffer, callback) {
  const outParts = [];
  const errParts = [];
  let outLen = 0;
  let errLen = 0;
  let overflow = null;
  let done = false;

  const finish = (error) => {
    if (done) return;
    done = true;
    callback(
      error,
      Buffer.concat(outParts).toString('utf8'),
      Buffer.concat(errParts).toString('utf8')
    );
  };

  child.stdout.on('data', (chunk) => {
    outLen += chunk.length;
    if (outLen > maxBuffer) {
      if (!overflow) {
        overflow = errWithCode('ENOBUFS', 'stdout maxBuffer length exceeded');
        child.kill('SIGTERM');
      }
      return;
    }
    outParts.push(chunk);
  });
  child.stderr.on('data', (chunk) => {
    errLen += chunk.length;
    if (errLen > maxBuffer) {
      if (!overflow) {
        overflow = errWithCode('ENOBUFS', 'stderr maxBuffer length exceeded');
        child.kill('SIGTERM');
      }
      return;
    }
    errParts.push(chunk);
  });

  child.on('error', (err) => finish(err));
  child.on('close', (code, signal) => {
    if (overflow) {
      overflow.killed = child.killed;
      overflow.signal = signal;
      finish(overflow);
      return;
    }
    if (signal) {
      const err = new Error(`Command terminated by ${signal}`);
      err.code = null;
      err.signal = signal;
      err.killed = child.killed;
      finish(err);
      return;
    }
    if (code !== 0) {
      const err = new Error(`Command failed with exit code ${code}`);
      err.code = code; // Node puts the numeric exit code in error.code
      err.killed = child.killed;
      finish(err);
      return;
    }
    finish(null);
  });
}

/**
 * exec(command[, options], callback) — shell argv per spec:
 * [shell, "-c", command]; shell defaults to "/bin/sh" and is overridable
 * via options.shell. maxBuffer default 1 MB.
 */
function exec(command, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = options || {};
  const shell = options.shell || DEFAULT_SHELL;
  const child = spawn(shell, ['-c', String(command)], { ...options, stdio: ['pipe', 'pipe', 'pipe'] });
  bufferChild(child, Number.isInteger(options.maxBuffer) ? options.maxBuffer : DEFAULT_MAX_BUFFER, callback);
  return child;
}

/** execFile(file[, args][, options], callback) — no shell. */
function execFile(file, args, options, callback) {
  if (typeof args === 'function') {
    callback = args;
    args = [];
    options = {};
  } else if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = options || {};
  const child = spawn(file, Array.isArray(args) ? args : [], {
    ...options,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  bufferChild(child, Number.isInteger(options.maxBuffer) ? options.maxBuffer : DEFAULT_MAX_BUFFER, callback);
  return child;
}

/** execSync(command[, options]) — implemented over the spawnSync sync path. */
function execSync(command, options = {}) {
  const shell = options.shell || DEFAULT_SHELL;
  const result = spawnSync(shell, ['-c', String(command)], options);
  if (result.error) throw result.error;
  if (result.signal) {
    const err = new Error(`Command terminated by ${result.signal}`);
    err.status = result.status;
    err.signal = result.signal;
    err.stdout = result.stdout;
    err.stderr = result.stderr;
    throw err;
  }
  if (result.status !== 0) {
    const err = new Error(`Command failed: ${command}`);
    err.status = result.status;
    err.stdout = result.stdout;
    err.stderr = result.stderr;
    throw err;
  }
  return result.stdout;
}

// ----------------------------------------------------------------- spawnSync

/**
 * spawnSync over a SECOND, dedicated connection (role "node-shim-sync").
 * The whole job runs request-by-request: hello → spawn.start → interleaved
 * spawn.stdin / flow.ack / event pumping via synchronous stream reads, until
 * spawn.exit arrives. See HANDOFF.md for the two-connection design.
 */
function spawnSync(command, args, options) {
  const norm = normalizeArgs(args, options);
  const opts = norm.options;

  const encodeResult = (fields) => ({
    pid: undefined,
    output: [null, null, null],
    stdout: opts.encoding === null || opts.encoding === 'buffer' ? Buffer.alloc(0) : '',
    stderr: opts.encoding === null || opts.encoding === 'buffer' ? Buffer.alloc(0) : '',
    status: null,
    signal: null,
    error: undefined,
    ...fields,
  });

  if (!ctx || typeof ctx.connectSync !== 'function') {
    return encodeResult({
      error: errWithCode('ENOSYS', 'spawnSync requires a connect factory (tether-shim not installed)'),
    });
  }

  const asText = (buf) =>
    opts.encoding === null || opts.encoding === 'buffer' ? buf : buf.toString(opts.encoding || 'utf8');

  let stream;
  try {
    stream = ctx.connectSync();
  } catch (err) {
    return encodeResult({ error: err });
  }

  const syncClient = new Client(stream, {
    role: 'node-shim-sync',
    sync: true,
    onFatal: (reason) => {
      throw errWithCode('EPROTO', `sync IPC connection lost (${reason})`);
    },
  });

  const outParts = [];
  const errParts = [];
  let exitInfo = null;
  let pid = null;

  // The sync connection is dedicated to this one job, so every spawn.*
  // event on it belongs to this child — even ones that arrive before the
  // spawn.start response has been processed (pid still unknown locally).
  syncClient.on('evt:spawn.stdout', (body) => {
    if (pid !== null && body.pid !== pid) return;
    const buf = Buffer.from(body.dataB64 || '', 'base64');
    outParts.push(buf);
    syncClient.send('flow.ack', { pid: body.pid, bytes: buf.length }); // consumed immediately
  });
  syncClient.on('evt:spawn.stderr', (body) => {
    if (pid !== null && body.pid !== pid) return;
    const buf = Buffer.from(body.dataB64 || '', 'base64');
    errParts.push(buf);
    syncClient.send('flow.ack', { pid: body.pid, bytes: buf.length });
  });
  syncClient.on('evt:spawn.exit', (body) => {
    if (pid !== null && body.pid !== pid) return;
    exitInfo = {
      code: body.code === undefined ? null : body.code,
      signal: body.signal === undefined ? null : body.signal,
    };
  });

  try {
    const helloRes = syncClient.requestSync('hello', {
      proto: PROTO,
      role: 'node-shim-sync',
      features: FEATURES,
    });
    if (!helloRes.ok) {
      return encodeResult({ error: errWithCode(helloRes.code || 'EPROTO', helloRes.message || 'sync handshake rejected') });
    }

    const startRes = syncClient.requestSync('spawn.start', {
      argv: [String(command), ...norm.args.map(String)],
      cwd: opts.cwd || process.cwd(),
      env: opts.env || process.env,
      stdio: normalizeStdio(opts.stdio),
      pty: !!opts.pty,
    });
    if (!startRes.ok || !Number.isInteger(startRes.pid)) {
      return encodeResult({
        error: errWithCode(startRes.code || 'EINVAL', startRes.message || 'sync spawn.start failed'),
      });
    }
    pid = startRes.pid;

    let input = null;
    if (opts.input !== undefined && opts.input !== null) {
      input = Buffer.isBuffer(opts.input) ? opts.input : Buffer.from(String(opts.input));
    }
    let inputOffset = 0;
    let window = Number.POSITIVE_INFINITY;
    let stdinEndedSent = false;

    while (exitInfo === null) {
      // 1. Push input while the server reports capacity.
      if (input !== null && inputOffset < input.length && window > 0) {
        const chunk = input.subarray(inputOffset, inputOffset + RAW_CHUNK_MAX);
        const res = syncClient.requestSync('spawn.stdin', { pid, dataB64: chunk.toString('base64') });
        if (!res.ok) {
          return encodeResult({ pid, error: errWithCode(res.code || 'EPIPE', res.message || 'sync spawn.stdin failed') });
        }
        inputOffset += chunk.length;
        if (Number.isInteger(res.window)) window = res.window;
        continue;
      }
      // 2. Close stdin once input is exhausted.
      const inputDone = input === null || inputOffset >= input.length;
      if (inputDone && !stdinEndedSent) {
        const res = syncClient.requestSync('spawn.stdinEnd', { pid });
        stdinEndedSent = true;
        if (!res.ok) {
          return encodeResult({ pid, error: errWithCode(res.code || 'EPIPE', res.message || 'sync spawn.stdinEnd failed') });
        }
        continue;
      }
      // 3. Otherwise pump the stream: stdout/stderr events, acks, exit.
      if (syncClient.pumpOnce()) continue;
      // Nothing to send and nothing readable: the host's blocking read should
      // never return empty mid-session. Fail loud rather than spin.
      return encodeResult({
        pid,
        error: errWithCode('EAGAIN', 'spawnSync stalled waiting for child output or exit'),
      });
    }

    const stdoutBuf = Buffer.concat(outParts);
    const stderrBuf = Buffer.concat(errParts);
    return {
      pid,
      output: [null, stdoutBuf, stderrBuf],
      stdout: asText(stdoutBuf),
      stderr: asText(stderrBuf),
      status: exitInfo.code,
      signal: exitInfo.signal,
      error: undefined,
    };
  } catch (err) {
    return encodeResult({ pid: pid === null ? undefined : pid, error: err });
  } finally {
    syncClient.dispose();
  }
}

module.exports = {
  spawn,
  spawnSync,
  exec,
  execFile,
  execSync,
  ChildProcess,
  // Delegated to the real module (outside the TJIP/2 protocol surface):
  fork: realChildProcess.fork,
  // Internals used by install()/tests:
  attach,
  detach,
  DEFAULT_SHELL,
  RAW_CHUNK_MAX,
  DEFAULT_MAX_BUFFER,
};
