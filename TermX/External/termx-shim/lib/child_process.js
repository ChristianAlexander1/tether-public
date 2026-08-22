'use strict';

/**
 * lib/child_process.js — a Node-accurate replacement for the `child_process`
 * module. Every operation is forwarded over the TermX JSON IPC channel
 * (see ./ipc.js) to the app's in-process command engine, which runs the
 * command and returns its full output. This is what lets `npm install` and
 * Claude Code work inside an iOS app where real child processes are forbidden.
 *
 * Surface implemented: spawn, spawnSync, exec, execSync, execFile, execFileSync,
 * fork, and the ChildProcess class. Return/throw shapes match Node as closely
 * as the protocol allows so npm can inspect them.
 */

const { EventEmitter } = require('events');
const { Readable, Writable } = require('stream');
const ipc = require('./ipc');

const SHELL = '/bin/sh';
const DEFAULT_MAX_BUFFER = 1024 * 1024; // 1 MiB, matches Node's exec/execFile default.

// ---------------------------------------------------------------------------
// Argument normalisation.
// ---------------------------------------------------------------------------

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

/**
 * Normalise spawn/spawnSync/file-family arguments.
 * Accepts: (file), (file, args), (file, options), (file, args, options).
 */
function normalizeSpawnArgs(file, args, options) {
  if (options === undefined) {
    if (args === undefined || args === null) {
      options = {};
      args = [];
    } else if (Array.isArray(args)) {
      options = {};
    } else {
      // spawn(file, options)
      options = args;
      args = [];
    }
  } else {
    if (args === undefined || args === null) args = [];
  }
  return { file, args: args.slice(), options: options || {} };
}

/** Outer shell quoting for a single token in a shell command string. */
function quoteForShell(s) {
  if (typeof s !== 'string') s = String(s);
  if (/^[A-Za-z0-9_\-./=:@,+]+$/.test(s)) return s;
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

/** Reconstruct the shell command Node would build from (file, args). */
function buildCommand(file, args) {
  const parts = [file, ...(args || [])];
  return parts.map(quoteForShell).join(' ');
}

/** Resolve the configured encoding to null (Buffer) or a string. */
function toEncoding(options) {
  let enc = options.encoding;
  if (enc === 'buffer') return null;
  if (enc === undefined || enc === null) return null;
  return String(enc);
}

// ---------------------------------------------------------------------------
// Request building.
// ---------------------------------------------------------------------------

function buildRequest(file, args, options, op) {
  const shell = options.shell;
  let finalFile = file;
  let finalArgs = args;
  if (shell) {
    finalFile = typeof shell === 'string' ? shell : SHELL;
    finalArgs = ['-c', buildCommand(file, args)];
  }

  const req = {
    op: op || 'spawnSync',
    file: finalFile,
    args: finalArgs,
    cwd: options.cwd || process.cwd(),
    env: options.env || process.env,
    shell: !!shell,
    interactive: ipc.isInteractive(),
  };
  if (options.timeout !== undefined && options.timeout !== null) req.timeout = options.timeout;
  if (options.killSignal !== undefined && options.killSignal !== null) req.killSignal = options.killSignal;
  if (options.argv0 !== undefined && options.argv0 !== null) req.argv0 = options.argv0;
  return req;
}

// ---------------------------------------------------------------------------
// stdio interpretation.
// ---------------------------------------------------------------------------

function stdioModeAt(stdio, index) {
  let v = Array.isArray(stdio) ? stdio[index] : stdio;
  if (v === undefined || v === null) return 'pipe';
  if (v === 'pipe' || v === 'overlapped' || v === 'ipc') return 'pipe';
  if (v === 'inherit' || typeof v === 'number') return 'inherit';
  if (v === 'ignore') return 'ignore';
  return 'pipe';
}

// ---------------------------------------------------------------------------
// Errors.
// ---------------------------------------------------------------------------

function makeSpawnError(file, args, reply) {
  const err = new Error('spawn ' + file + ' ' + (reply.error || reply.code || ''));
  err.errno = -2;
  err.code = reply.code || 'ENOENT';
  err.syscall = 'spawn ' + file;
  err.path = file;
  err.spawnargs = args.slice();
  return err;
}

function makeGenericError(file, args, cause) {
  const err = new Error('spawn ' + file + ' ' + (cause && cause.message ? cause.message : cause));
  err.errno = -2;
  err.code = 'ENOENT';
  err.syscall = 'spawn ' + file;
  err.path = file;
  err.spawnargs = args.slice();
  err.cause = cause;
  return err;
}

// ---------------------------------------------------------------------------
// Result decoding.
// ---------------------------------------------------------------------------

/** Decode a (string) output payload according to 'encoding'; null means Buffer. */
function decodeOut(value, encoding) {
  const str = value || '';
  if (encoding === null) return Buffer.from(str, 'utf8');
  return Buffer.from(str, 'utf8').toString(encoding);
}

// ---------------------------------------------------------------------------
// The synchronous core. Returns a Node-shaped spawnSync result.
// ---------------------------------------------------------------------------

function spawnSync(file, args, options) {
  const n = normalizeSpawnArgs(file, args, options);
  const opts = n.options;
  const enc = toEncoding(opts);
  const req = buildRequest(n.file, n.args, opts, 'spawnSync');
  req.encoding = enc === null ? 'buffer' : enc;

  const sIn = stdioModeAt(opts.stdio, 0);
  const sOut = stdioModeAt(opts.stdio, 1);
  const sErr = stdioModeAt(opts.stdio, 2);
  if (sIn === 'pipe' && opts.input !== undefined && opts.input !== null) {
    req.input = opts.input;
  }

  let reply;
  try {
    reply = ipc.roundTrip(req);
  } catch (cause) {
    return {
      pid: null,
      output: [null, null, null],
      stdout: null,
      stderr: null,
      status: null,
      signal: null,
      error: makeGenericError(n.file, n.args, cause),
    };
  }

  const pid = reply.pid == null ? null : reply.pid;

  // Could not start the command.
  if (reply.error) {
    return {
      pid,
      output: [null, null, null],
      stdout: null,
      stderr: null,
      status: null,
      signal: null,
      error: makeSpawnError(n.file, n.args, reply),
    };
  }

  // Ended because of a signal (only reachable for a timeout in practice).
  if (reply.signal && (reply.exitCode === null || reply.exitCode === undefined)) {
    if (opts.timeout !== undefined && opts.timeout !== null) {
      const err = new Error('spawnSync ' + n.file + ' ETIMEDOUT');
      err.errno = 'ETIMEDOUT';
      err.code = 'ETIMEDOUT';
      err.signal = reply.signal;
      err.killed = true;
      return { pid, output: [null, null, null], stdout: null, stderr: null, status: null, signal: reply.signal, error: err };
    }
    return { pid, output: [null, null, null], stdout: null, stderr: null, status: null, signal: reply.signal || null, error: null };
  }

  let stdout = null;
  let stderr = null;
  if (sOut === 'pipe') stdout = decodeOut(reply.stdout, enc);
  if (sErr === 'pipe') stderr = decodeOut(reply.stderr, enc);
  if (sOut === 'inherit' && reply.stdout) process.stdout.write(reply.stdout);
  if (sErr === 'inherit' && reply.stderr) process.stderr.write(reply.stderr);

  const output = [null, stdout, stderr];

  // maxBuffer overflow.
  const maxBuffer = opts.maxBuffer;
  if (maxBuffer !== undefined && maxBuffer !== null) {
    const bytes = Buffer.byteLength(reply.stdout || '', 'utf8') + Buffer.byteLength(reply.stderr || '', 'utf8');
    if (bytes > maxBuffer) {
      const err = new Error('spawnSync ' + n.file + ' ERR_CHILD_PROCESS_STDIO_MAXBUFFER');
      err.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER';
      err.errno = null;
      err.killed = true;
      return { pid, output, stdout, stderr, status: null, signal: null, error: err };
    }
  }

  return {
    pid,
    output,
    stdout,
    stderr,
    status: reply.exitCode == null ? null : reply.exitCode,
    signal: reply.signal || null,
    error: null,
  };
}

// ---------------------------------------------------------------------------
// ChildProcess (async spawn).
// ---------------------------------------------------------------------------

class ChildProcess extends EventEmitter {
  constructor() {
    super();
    this.pid = undefined;
    this.connected = false;
    this._exitCode = null;
    this._signalCode = null;
    this._killed = false;
    this._spawned = false;
    this._exited = false;
    this._refed = true;
  }

  get exitCode() {
    return this._exitCode;
  }
  get signalCode() {
    return this._signalCode;
  }
  get killed() {
    return this._killed;
  }
  get spawnfile() {
    return this._spawnfile;
  }

  kill(signal) {
    signal = signal || 'SIGTERM';
    if (this._exited || this.pid == null) return false;
    this._killed = true;
    try {
      ipc.roundTrip({ op: 'signal', pid: this.pid, signal });
    } catch (_) {
      // The engine is gone; treat as best-effort.
    }
    return true;
  }

  ref() {
    this._refed = true;
    return this;
  }
  unref() {
    this._refed = false;
    return this;
  }
  hasRef() {
    return this._refed;
  }

  /** fork() IPC surface. Without a message channel these are faithful no-ops. */
  disconnect() {}
  send() {
    return false;
  }
}

function feedStream(stream, text) {
  if (!stream) return;
  if (stream === process.stdout || stream === process.stderr) {
    if (text) stream.write(String(text));
    return;
  }
  if (typeof stream.push === 'function') {
    if (text != null) stream.push(String(text));
    stream.push(null);
  }
}

function errorChild(child, err) {
  child._exitCode = null;
  child._signalCode = null;
  child._exited = true;
  child.emit('error', err);
  child.emit('close', null, null);
}

function buildSpawnStreams(child, sIn, sOut, sErr) {
  if (sOut === 'pipe') child.stdout = new Readable({ read() {} });
  else if (sOut === 'inherit') child.stdout = process.stdout;
  else child.stdout = null;

  if (sErr === 'pipe') child.stderr = new Readable({ read() {} });
  else if (sErr === 'inherit') child.stderr = process.stderr;
  else child.stderr = null;

  if (sIn === 'pipe') child.stdin = new Writable({ write(_c, _e, cb) { cb(); } });
  else if (sIn === 'inherit') child.stdin = process.stdin;
  else child.stdin = null;
}

function spawn(file, args, options) {
  const n = normalizeSpawnArgs(file, args, options);
  const opts = n.options;
  const enc = toEncoding(opts);
  const sIn = stdioModeAt(opts.stdio, 0);
  const sOut = stdioModeAt(opts.stdio, 1);
  const sErr = stdioModeAt(opts.stdio, 2);

  const child = new ChildProcess();
  child._spawnfile = n.file;
  child._spawnargs = n.args.slice();
  buildSpawnStreams(child, sIn, sOut, sErr);

  const req = buildRequest(n.file, n.args, opts, 'spawn');
  req.encoding = enc === null ? 'buffer' : enc;
  if (sIn === 'pipe' && opts.input !== undefined && opts.input !== null) req.input = opts.input;

  // Dispatch on a later tick so callers have attached their listeners first.
  process.nextTick(() => {
    let reply;
    try {
      reply = ipc.roundTrip(req);
    } catch (cause) {
      errorChild(child, makeGenericError(n.file, n.args, cause));
      return;
    }

    if (reply.error) {
      errorChild(child, makeSpawnError(n.file, n.args, reply));
      return;
    }

    child.pid = reply.pid;
    child._spawned = true;
    child.emit('spawn');

    // The app returns full output after completion; feed the streams once.
    feedStream(child.stdout, reply.stdout);
    feedStream(child.stderr, reply.stderr);

    child._exitCode = reply.exitCode == null ? null : reply.exitCode;
    child._signalCode = reply.signal || null;
    child._exited = true;
    if (child.stdin && sIn === 'pipe') child.stdin.end();

    child.emit('exit', child.exitCode, child.signalCode);
    child.emit('close', child.exitCode, child.signalCode);
  });

  return child;
}

// ---------------------------------------------------------------------------
// exec / execFile (async) and their sync variants.
// ---------------------------------------------------------------------------

/** Translate a spawnSync result into Node's exec error shape (or null). */
function normalizeExecError(cmd, result) {
  if (result.error) {
    const err = result.error;
    err.cmd = cmd;
    err.killed = !!result.signal || !!err.killed;
    err.status = result.status;
    err.signal = result.signal != null ? result.signal : null;
    err.stdout = result.stdout;
    err.stderr = result.stderr;
    return err;
  }
  if (result.status !== 0) {
    const err = new Error('Command failed: ' + cmd + (result.stderr ? '\n' + result.stderr : ''));
    err.cmd = cmd;
    err.killed = !!result.signal;
    err.code = result.status;
    err.status = result.status;
    err.signal = result.signal != null ? result.signal : null;
    err.stdout = result.stdout;
    err.stderr = result.stderr;
    return err;
  }
  return null;
}

function exec(command, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = options || {};
  if (typeof callback !== 'function') {
    throw new TypeError('The "callback" argument must be of type function.');
  }
  const shell = typeof options.shell === 'string' ? options.shell : SHELL;
  const eff = Object.assign({}, options, {
    encoding: options.encoding == null ? 'utf8' : options.encoding,
    maxBuffer: options.maxBuffer == null ? DEFAULT_MAX_BUFFER : options.maxBuffer,
  });
  const result = spawnSync(shell, ['-c', command], eff);
  process.nextTick(() => callback(normalizeExecError(command, result), result.stdout, result.stderr));
}

function execFile(file, args, options, callback) {
  if (typeof args === 'function') {
    callback = args;
    args = [];
    options = {};
  } else if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  if (args == null) args = [];
  options = options || {};
  if (typeof callback !== 'function') {
    throw new TypeError('The "callback" argument must be of type function.');
  }
  const eff = Object.assign({}, options, {
    encoding: options.encoding == null ? 'utf8' : options.encoding,
    maxBuffer: options.maxBuffer == null ? DEFAULT_MAX_BUFFER : options.maxBuffer,
  });
  const cmd = buildCommand(file, args);
  const result = spawnSync(file, args, eff);
  process.nextTick(() => callback(normalizeExecError(cmd, result), result.stdout, result.stderr));
}

function execSync(command, options) {
  options = options || {};
  const eff = Object.assign({}, options, {
    encoding: options.encoding == null ? 'utf8' : options.encoding,
    maxBuffer: options.maxBuffer == null ? DEFAULT_MAX_BUFFER : options.maxBuffer,
  });
  const result = spawnSync(SHELL, ['-c', command], eff);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const err = new Error('Command failed: ' + command + (result.stderr ? '\n' + result.stderr : ''));
    err.cmd = command;
    err.killed = !!result.signal;
    err.code = result.status;
    err.status = result.status;
    err.signal = result.signal != null ? result.signal : null;
    err.stdout = result.stdout;
    err.stderr = result.stderr;
    throw err;
  }
  return result.stdout;
}

function execFileSync(file, args, options) {
  if (isPlainObject(args)) {
    options = args;
    args = [];
  }
  args = args || [];
  options = options || {};
  const eff = Object.assign({}, options, {
    encoding: options.encoding == null ? 'utf8' : options.encoding,
    maxBuffer: options.maxBuffer == null ? DEFAULT_MAX_BUFFER : options.maxBuffer,
  });
  const cmd = buildCommand(file, args);
  const result = spawnSync(file, args, eff);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const err = new Error('Command failed: ' + cmd + (result.stderr ? '\n' + result.stderr : ''));
    err.cmd = cmd;
    err.killed = !!result.signal;
    err.code = result.status;
    err.status = result.status;
    err.signal = result.signal != null ? result.signal : null;
    err.stdout = result.stdout;
    err.stderr = result.stderr;
    throw err;
  }
  return result.stdout;
}

// ---------------------------------------------------------------------------
// fork — same channel, faithful object shape.
//
// The wire protocol carries no message stream, so fork() runs the module via
// the normal spawn path and exposes the IPC surface as a faithful facade;
// send() returns false and 'message' events never fire. See HANDOFF.md.
// ---------------------------------------------------------------------------

function fork(modulePath, args, options) {
  if (isPlainObject(args)) {
    options = args;
    args = [];
  }
  args = args || [];
  options = options || {};
  const execPath = process.env.TERMX_NODE_EXEC || process.execPath || 'node';
  const child = spawn(execPath, [modulePath, ...args], Object.assign({}, options, { stdio: options.stdio || 'inherit' }));
  // Keep the facade even though there is no real message channel.
  child.connected = false;
  return child;
}

module.exports = {
  spawn,
  spawnSync,
  exec,
  execSync,
  execFile,
  execFileSync,
  fork,
  ChildProcess,
};
