'use strict';

// lib/spawn.js — Bun.spawn / Bun.spawnSync mapped onto an injected
// child_process-compatible { spawn, spawnSync }.
//
// Design notes (see HANDOFF.md for more):
//   * Bun's first argument is a string[] argv; Node's child_process
//     spawn takes (command, args). We split argv into [command, ...rest].
//   * stdout:"pipe" yields a WHATWG ReadableStream via
//     stream.Readable.toWeb. "inherit" / "ignore" map through.
//   * Bun throws ENOENT synchronously; Node's ChildProcess emits it as
//     an asynchronous 'error' event. We bridge this two ways:
//       (a) If the injected spawnImpl.spawn throws synchronously (as a
//           fake or a future impl may), we rethrow unchanged.
//       (b) We attach an 'error' listener BEFORE returning from
//           Bun.spawn so that an asynchronously-emitted ENOENT (or any
//           other spawn error) can never become an unhandled 'error'
//           event. The error is surfaced via onExit and `exited`, and
//           never produces an unhandled rejection.
//     Tests use a fake that throws ENOENT synchronously, which is the
//     Bun-faithful path.

const { Readable } = require('node:stream');
const { EventEmitter } = require('node:events');

const SIGNAL_NUMBERS = {
  SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGILL: 4, SIGTRAP: 5,
  SIGABRT: 6, SIGBUS: 7, SIGFPE: 8, SIGKILL: 9, SIGUSR1: 10,
  SIGSEGV: 11, SIGUSR2: 12, SIGPIPE: 13, SIGALRM: 14, SIGTERM: 15,
};

function signalToNumber(sig) {
  if (typeof sig === 'number') return sig;
  if (typeof sig === 'string') {
    const s = sig.toUpperCase();
    if (SIGNAL_NUMBERS[s] != null) return SIGNAL_NUMBERS[s];
    const n = Number(s);
    if (Number.isFinite(n)) return n;
  }
  return 15;
}

function mapStdio(v) {
  if (v === 'pipe' || v === 'inherit' || v === 'ignore') return v;
  if (v == null) return undefined;
  return v; // numeric fd or existing stream — pass through
}

function toWebStream(nodeStream) {
  if (!nodeStream) return null;
  try {
    return Readable.toWeb(nodeStream);
  } catch (e) {
    return null;
  }
}

function toError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function parseArgv(cmd) {
  if (Array.isArray(cmd)) {
    if (cmd.length === 0) {
      throw toError('ERR_MISSING_ARGS', 'spawn requires at least one argument');
    }
    return { command: cmd[0], args: cmd.slice(1) };
  }
  if (typeof cmd === 'object' && cmd !== null && Array.isArray(cmd.cmd)) {
    if (cmd.cmd.length === 0) {
      throw toError('ERR_MISSING_ARGS', 'spawn requires at least one argument');
    }
    return { command: cmd.cmd[0], args: cmd.cmd.slice(1) };
  }
  if (typeof cmd === 'string') {
    return { command: cmd, args: [] };
  }
  throw new TypeError('spawn: first argument must be string[] or {cmd:string[]}');
}

function createSpawnApi(spawnImpl) {
  function spawn(cmd, options) {
    const opts = options || {};
    const { command, args } = parseArgv(cmd);

    const nodeOpts = {
      cwd: opts.cwd,
      env: opts.env,
      stdio: [
        mapStdio(opts.stdin),
        mapStdio(opts.stdout),
        mapStdio(opts.stderr),
      ],
    };

    // (a) Synchronous throw path: the impl may throw ENOENT itself.
    let child;
    try {
      child = spawnImpl.spawn(command, args, nodeOpts);
    } catch (e) {
      throw e;
    }

    const subprocess = new EventEmitter();
    subprocess.pid = child.pid;

    const stdinWeb = opts.stdin === 'pipe' ? child.stdin : null;
    const stdoutWeb = opts.stdout === 'pipe' ? toWebStream(child.stdout) : null;
    const stderrWeb = opts.stderr === 'pipe' ? toWebStream(child.stderr) : null;

    Object.defineProperties(subprocess, {
      stdin: { value: stdinWeb, enumerable: true, configurable: false, writable: false },
      stdout: { value: stdoutWeb, enumerable: true, configurable: false, writable: false },
      stderr: { value: stderrWeb, enumerable: true, configurable: false, writable: false },
    });

    let exitedResolve;
    const exited = new Promise((resolve) => { exitedResolve = resolve; });
    subprocess.exited = exited;
    subprocess.exitCode = undefined;
    subprocess.signalCode = undefined;

    let settled = false;
    function settle(exitCode, signalCode, err) {
      if (settled) return;
      settled = true;
      subprocess.exitCode = exitCode;
      subprocess.signalCode = signalCode;
      if (typeof opts.onExit === 'function') {
        try { opts.onExit(subprocess, exitCode, signalCode, err); } catch (_) { /* swallow */ }
      }
      exitedResolve(exitCode);
    }

    // (b) Attach listeners BEFORE returning so no event can go unhandled.
    child.on('error', (err) => {
      // Spawn failure (e.g. async ENOENT). Never rejects; resolves null.
      settle(null, null, err);
    });

    child.on('close', (code, signal) => {
      if (signal) {
        // Bun: exited resolves with 128+signo, exitCode stays null,
        // signalCode is set to the signal name.
        subprocess.exitCode = null;
        subprocess.signalCode = signal;
        if (typeof opts.onExit === 'function') {
          try { opts.onExit(subprocess, 128 + signalToNumber(signal), signal, null); } catch (_) {}
        }
        if (!settled) {
          settled = true;
          exitedResolve(128 + signalToNumber(signal));
        }
      } else {
        settle(code == null ? 0 : code, null, null);
      }
    });

    subprocess.kill = function kill(signal) {
      try {
        return child.kill ? child.kill(signal || 'SIGTERM') : false;
      } catch (e) {
        return false;
      }
    };
    subprocess.unref = function unref() { if (child.unref) child.unref(); return subprocess; };
    subprocess.ref = function ref() { if (child.ref) child.ref(); return subprocess; };

    return subprocess;
  }

  function spawnSync(cmd, options) {
    const opts = options || {};
    const { command, args } = parseArgv(cmd);

    const nodeOpts = {
      cwd: opts.cwd,
      env: opts.env,
      stdio: [
        mapStdio(opts.stdin),
        mapStdio(opts.stdout),
        mapStdio(opts.stderr),
      ],
    };
    if (opts.stdout === 'pipe' || opts.stderr === 'pipe') {
      nodeOpts.encoding = 'buffer';
    }

    const res = spawnImpl.spawnSync(command, args, nodeOpts);
    const exitCode = (res && typeof res.status === 'number') ? res.status : null;
    const signalCode = (res && res.signal) ? res.signal : null;
    return {
      success: exitCode === 0 && !signalCode,
      exitCode,
      signalCode,
      stdout: (res && res.stdout) ? res.stdout : Buffer.alloc(0),
      stderr: (res && res.stderr) ? res.stderr : Buffer.alloc(0),
    };
  }

  return { spawn, spawnSync };
}

module.exports = { createSpawnApi, signalToNumber };
