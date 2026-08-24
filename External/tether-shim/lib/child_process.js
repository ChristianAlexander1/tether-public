'use strict';

const { EventEmitter } = require('events');
const { Writable, PassThrough } = require('stream');
const ipc = require('./ipc');

const ENOENT_ERRNO = -2;

function enoentError(file, syscall) {
  const err = new Error(`spawn ${file} ENOENT`);
  err.code = 'ENOENT';
  err.errno = ENOENT_ERRNO;
  err.syscall = syscall || `spawn ${file}`;
  err.path = file;
  err.spawnargs = [];
  return err;
}



function normalizeArgs(file, args, options, callback) {
  if (typeof args === 'function') {
    callback = args;
    args = [];
    options = {};
  } else if (args && !Array.isArray(args) && typeof args === 'object') {
    callback = options;
    options = args;
    args = [];
  } else if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  args = args ? [...args] : [];
  options = options || {};
  return { file, args, options, callback };
}

function envFrom(options) {
  if (options.env && typeof options.env === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(options.env)) {
      if (v !== undefined && v !== null) out[k] = String(v);
    }
    return out;
  }
  // Pass parent env through unchanged (DISPLAY, BROWSER, WAYLAND_DISPLAY, …)
  return { ...process.env };
}

function resolveShell(options) {
  if (!options.shell) return null;
  if (options.shell === true) return { file: 'sh', prefix: ['-c'] };
  const sh = String(options.shell);
  return { file: sh, prefix: ['-c'] };
}

function buildCommand(file, args, options) {
  const shell = resolveShell(options);
  if (shell) {
    const cmd = [file, ...args].join(' ');
    return { file: shell.file, args: [...shell.prefix, cmd] };
  }
  return { file, args };
}

function parseStdio(stdio) {
  if (stdio == null) return ['pipe', 'pipe', 'pipe'];
  if (typeof stdio === 'string') {
    if (stdio === 'pipe') return ['pipe', 'pipe', 'pipe'];
    if (stdio === 'ignore') return ['ignore', 'ignore', 'ignore'];
    if (stdio === 'inherit') return ['inherit', 'inherit', 'inherit'];
    return [stdio, stdio, stdio];
  }
  return stdio;
}

let _nextPid = 40000;
function nextPid() {
  return _nextPid++;
}

function applyStdioLayout(child, options) {
  const spec = parseStdio(options && options.stdio);
  child._stdioSpec = spec;
  const makeIn = () =>
    new Writable({
      write: (chunk, enc, cb) => {
        child._stdinBuf.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, enc));
        cb();
      },
    });
  const slot = (i, piped) => {
    const s = spec[i];
    if (s === 'ignore' || s === 'inherit' || s === 0 || s === 1 || s === 2) return null;
    return piped;
  };
  child.stdin = slot(0, makeIn());
  child.stdout = slot(1, new PassThrough());
  child.stderr = slot(2, new PassThrough());
  child.stdio = [child.stdin, child.stdout, child.stderr];
}

class ChildProcess extends EventEmitter {
  constructor() {
    super();
    this.stdin = null;
    this.stdout = null;
    this.stderr = null;
    this.stdio = [null, null, null];
    this.pid = undefined;
    this.connected = false;
    this.exitCode = null;
    this.signalCode = null;
    this.killed = false;
    this.spawnfile = undefined;
    this.spawnargs = [];
    this._stdinBuf = [];
    this._killed = false;
    this._closed = false;
  }

  kill(signal) {
    this.killed = true;
    this._killed = true;
    if (this._closed) return true;
    const sig = signal || 'SIGTERM';
    this.signalCode = typeof sig === 'string' ? sig : String(sig);
    ipc
      .sendRequest({ kind: 'cancel', signal: this.signalCode, pid: this.pid })
      .then((reply) => {
        this._applyReply(reply, { fromKill: true });
      })
      .catch(() => {
        this._applyReply(
          { ok: true, exitCode: 130, stdout: '', stderr: '', pid: this.pid },
          { fromKill: true }
        );
      });
    return true;
  }

  send() {
    return false;
  }

  disconnect() {
    this.connected = false;
  }

  unref() {}
  ref() {}

  _applyReply(reply, extra) {
    extra = extra || {};
    if (this._closed) return;
    this._closed = true;
    if (this._killed && reply) {
      reply = { ...reply, ok: true, exitCode: 130 };
    }

    if (reply && reply.ok === false && reply.code === 'ENOENT') {
      const err = enoentError(this.spawnfile, `spawn ${this.spawnfile}`);
      err.spawnargs = this.spawnargs.slice(1);
      process.nextTick(() => {
        this.emit('error', err);
        this.exitCode = null;
        this._endStdio();
        this.emit('close', null, null);
      });
      return;
    }

    const stdout = (reply && reply.stdout) || '';
    const stderr = (reply && reply.stderr) || '';
    const code = reply && reply.exitCode != null ? reply.exitCode : 0;
    if (reply && reply.pid) this.pid = reply.pid;

    process.nextTick(() => {
      if (stdout && this.stdout) this.stdout.write(stdout);
      if (stderr && this.stderr) this.stderr.write(stderr);
      this._endStdio();
      this.exitCode = code;
      if (code === 130 && !this.signalCode) this.signalCode = 'SIGINT';
      this.emit('exit', code, this.signalCode);
      this.emit('close', code, this.signalCode);
    });
  }

  _endStdio() {
    try {
      this.stdout.end();
    } catch (_) {}
    try {
      this.stderr.end();
    } catch (_) {}
    try {
      this.stdin.end();
    } catch (_) {}
  }
}

function spawn(file, args, options) {
  const n = normalizeArgs(file, args, options);
  file = n.file;
  args = n.args;
  options = n.options;

  const cmd = buildCommand(file, args, options);
  const child = new ChildProcess();
  applyStdioLayout(child, options);
  child.spawnfile = cmd.file;
  child.spawnargs = [cmd.file, ...cmd.args];
  child.pid = nextPid();

  const stdioSpec = parseStdio(options.stdio);
  const interactive =
    options.stdio === 'inherit' ||
    stdioSpec[0] === 'inherit' ||
    process.env.TETHER_INTERACTIVE === '1' ||
    !!options.interactive;

  const req = {
    kind: 'spawn',
    file: cmd.file,
    args: cmd.args,
    cwd: options.cwd || process.cwd(),
    env: envFrom(options),
    interactive: !!interactive,
    stdio: stdioSpec,
  };
  if (options.argv0) req.argv0 = options.argv0;
  if (options.timeout) req.timeout = options.timeout;
  if (options.maxBuffer) req.maxBuffer = options.maxBuffer;
  if (options.killSignal) req.killSignal = options.killSignal;
  if (options.encoding) req.encoding = options.encoding;

  const timeout = options.timeout;

  process.nextTick(() => {
    child.emit('spawn');
  });

  let timer = null;
  if (timeout && timeout > 0) {
    timer = setTimeout(() => {
      child.kill(options.killSignal || 'SIGTERM');
    }, timeout);
  }

  process.nextTick(() => {
    if (child._stdinBuf.length) {
      req.stdin = Buffer.concat(child._stdinBuf).toString('utf8');
    }
    ipc
      .sendRequest(req)
      .then((reply) => {
        if (timer) clearTimeout(timer);
        if (options.maxBuffer != null && reply) {
          const out = (reply.stdout || '') + (reply.stderr || '');
          const bytes = Buffer.byteLength(out);
          if (bytes > options.maxBuffer) {
            const err = new Error('maxBuffer exceeded');
            err.code = 'ENOBUFS';
            child.emit('error', err);
            reply = {
              ...reply,
              exitCode: reply.exitCode != null ? reply.exitCode : 1,
              stdout: (reply.stdout || '').slice(0, options.maxBuffer),
            };
          }
        }
        child._applyReply(reply);
      })
      .catch((err) => {
        if (timer) clearTimeout(timer);
        process.nextTick(() => {
          child.emit('error', err);
          child._endStdio();
          child.emit('close', null, null);
        });
      });
  });

  return child;
}

function applySyncResult(file, args, options, reply) {
  const encoding = options.encoding === undefined ? 'buffer' : options.encoding;
  const encode = (s) => {
    const str = s == null ? '' : String(s);
    if (encoding === 'buffer' || encoding === null) return Buffer.from(str);
    return Buffer.from(str).toString(encoding);
  };
  const status = reply && reply.exitCode != null ? reply.exitCode : 0;
  return {
    pid: (reply && reply.pid) || nextPid(),
    output: [null, encode(reply && reply.stdout), encode(reply && reply.stderr)],
    stdout: encode(reply && reply.stdout),
    stderr: encode(reply && reply.stderr),
    status,
    signal: status === 130 ? 'SIGINT' : null,
    error:
      reply && reply.ok === false && reply.code === 'ENOENT'
        ? enoentError(file, `spawnSync ${file}`)
        : undefined,
  };
}

function spawnSync(file, args, options) {
  const n = normalizeArgs(file, args, options);
  file = n.file;
  args = n.args;
  options = n.options || {};
  const cmd = buildCommand(file, args, options);
  const req = {
    kind: 'spawn',
    file: cmd.file,
    args: cmd.args,
    cwd: options.cwd || process.cwd(),
    env: envFrom(options),
    interactive: false,
    stdio: parseStdio(options.stdio),
  };
  if (options.maxBuffer) req.maxBuffer = options.maxBuffer;
  if (options.argv0) req.argv0 = options.argv0;
  if (options.killSignal) req.killSignal = options.killSignal;
  if (options.encoding) req.encoding = options.encoding;
  if (options.input != null) {
    req.stdin = Buffer.isBuffer(options.input)
      ? options.input.toString('utf8')
      : String(options.input);
  }
  let reply;
  try {
    reply = ipc.sendRequestSync(req, options.timeout);
  } catch (e) {
    if (e.code === 'ENOENT') {
      const r = applySyncResult(cmd.file, cmd.args, options, {
        ok: false,
        code: 'ENOENT',
        exitCode: null,
        stdout: '',
        stderr: '',
      });
      r.error = enoentError(cmd.file, `spawnSync ${cmd.file}`);
      r.status = null;
      return r;
    }
    throw e;
  }
  if (options.maxBuffer != null) {
    const bytes = Buffer.byteLength((reply.stdout || '') + (reply.stderr || ''));
    if (bytes > options.maxBuffer) {
      const err = new Error('maxBuffer exceeded');
      err.code = 'ENOBUFS';
      const r = applySyncResult(cmd.file, cmd.args, options, reply);
      r.error = err;
      return r;
    }
  }
  return applySyncResult(cmd.file, cmd.args, options, reply);
}

function exec(command, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = { ...options, shell: options && options.shell != null ? options.shell : true };
  const child = spawn(command, [], options);
  const maxBuffer = (options && options.maxBuffer) || 1024 * 1024;
  let stdout = '';
  let stderr = '';
  let exceeded = false;
  const enc = (options && options.encoding) || 'utf8';

  child.stdout.setEncoding(enc === 'buffer' ? undefined : enc);
  child.stderr.setEncoding(enc === 'buffer' ? undefined : enc);
  child.stdout.on('data', (d) => {
    stdout += d;
    if (Buffer.byteLength(stdout) > maxBuffer) exceeded = true;
  });
  child.stderr.on('data', (d) => {
    stderr += d;
    if (Buffer.byteLength(stderr) > maxBuffer) exceeded = true;
  });

  child.on('error', (err) => {
    if (callback) callback(err, stdout, stderr);
  });

  child.on('close', (code, signal) => {
    if (!callback) return;
    if (exceeded) {
      const err = new Error('maxBuffer exceeded');
      err.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER';
      err.stdout = stdout;
      err.stderr = stderr;
      return callback(err, stdout, stderr);
    }
    if (code !== 0) {
      const err = new Error(`Command failed: ${command}\n${stderr}`);
      err.code = code;
      err.killed = child.killed;
      err.signal = signal;
      err.cmd = command;
      err.stdout = stdout;
      err.stderr = stderr;
      return callback(err, stdout, stderr);
    }
    callback(null, stdout, stderr);
  });

  return child;
}

function execSync(command, options) {
  options = options || {};
  const r = spawnSync(command, [], { ...options, shell: options.shell != null ? options.shell : true });
  if (r.error) throw r.error;
  if (r.status !== 0) {
    const err = new Error(`Command failed: ${command}`);
    err.status = r.status;
    err.stdout = r.stdout;
    err.stderr = r.stderr;
    err.signal = r.signal;
    err.pid = r.pid;
    err.output = r.output;
    throw err;
  }
  return r.stdout;
}

function execFile(file, args, options, callback) {
  const n = normalizeArgs(file, args, options, callback);
  const child = spawn(n.file, n.args, { ...n.options, shell: false });
  const cb = n.callback;
  const maxBuffer = (n.options && n.options.maxBuffer) || 1024 * 1024;
  let stdout = '';
  let stderr = '';
  const enc = (n.options && n.options.encoding) || 'utf8';
  child.stdout.setEncoding(enc === 'buffer' ? undefined : enc);
  child.stderr.setEncoding(enc === 'buffer' ? undefined : enc);
  child.stdout.on('data', (d) => {
    stdout += d;
  });
  child.stderr.on('data', (d) => {
    stderr += d;
  });
  child.on('error', (err) => {
    if (cb) cb(err, stdout, stderr);
  });
  child.on('close', (code, signal) => {
    if (!cb) return;
    if (Buffer.byteLength(stdout) > maxBuffer) {
      const err = new Error('maxBuffer exceeded');
      err.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER';
      return cb(err, stdout, stderr);
    }
    if (code !== 0) {
      const err = new Error(`Command failed: ${n.file}`);
      err.code = code;
      err.signal = signal;
      return cb(err, stdout, stderr);
    }
    cb(null, stdout, stderr);
  });
  return child;
}

function execFileSync(file, args, options) {
  const n = normalizeArgs(file, args, options);
  const r = spawnSync(n.file, n.args, { ...n.options, shell: false });
  if (r.error) throw r.error;
  if (r.status !== 0) {
    const err = new Error(`Command failed: ${n.file}`);
    err.status = r.status;
    err.stdout = r.stdout;
    err.stderr = r.stderr;
    throw err;
  }
  return r.stdout;
}

function fork(modulePath, args, options) {
  // IPC channel to the child is not supported: the host runs the command
  // and only returns stdout/stderr/exit. `child.send` is a no-op (returns false).
  const n = normalizeArgs(process.execPath, [modulePath].concat(args || []), options);
  if (typeof args === 'object' && !Array.isArray(args) && args) {
    return spawn(process.execPath, [modulePath], args);
  }
  return spawn(process.execPath, [modulePath, ...(args || [])], options || {});
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
  _enoentError: enoentError,
};
