'use strict';

/**
 * Run a nested `node <script|-e>` inside the same V8 isolate.
 *
 * npm lifecycle scripts (postinstall, …) call child_process.spawnSync('node', …).
 * On iOS there is only one engine thread; routing that spawn back through the
 * Swift IPC bridge deadlocks the job that is already running. Inline execution
 * is the real Unix semantics for an embedded single-process Node: the script
 * runs, sees process / require / cwd / env, and can call process.exit without
 * killing the app (exit is trapped to end only the nested run).
 */

const path = require('path');
const Module = require('module');

function isNodeBinary(file) {
  if (!file || typeof file !== 'string') return false;
  if (file === process.execPath) return true;
  if (process.env.TERMX_NODE_EXEC && file === process.env.TERMX_NODE_EXEC) return true;
  const base = path.basename(file).replace(/\.exe$/i, '');
  return base === 'node' || base === 'nodejs';
}

/**
 * Strip node CLI flags and classify the remaining argv.
 * Supports the subset npm uses: script path, -e/--eval, -p/--print, -r/--require.
 */
function classifyArgv(argv) {
  const args = Array.isArray(argv) ? argv.slice() : [];
  const preloads = [];
  while (args.length) {
    const a = args[0];
    if (a === '-e' || a === '--eval') {
      return { kind: 'eval', source: args[1] || '', print: false, preloads, rest: args.slice(2) };
    }
    if (a === '-p' || a === '--print') {
      return { kind: 'eval', source: args[1] || '', print: true, preloads, rest: args.slice(2) };
    }
    if (a === '-r' || a === '--require') {
      if (args[1]) preloads.push(args[1]);
      args.splice(0, 2);
      continue;
    }
    if (a === '--') {
      args.shift();
      break;
    }
    if (typeof a === 'string' && a.startsWith('-')) {
      // Unknown flag with optional value — skip conservatively.
      if (a.includes('=') || args.length === 1 || String(args[1]).startsWith('-')) {
        args.shift();
      } else {
        args.splice(0, 2);
      }
      continue;
    }
    break;
  }
  if (!args.length) return { kind: 'empty', preloads, rest: [] };
  return { kind: 'script', script: args[0], preloads, rest: args.slice(1) };
}

function emptyResult(status, encoding) {
  const enc = encoding === undefined || encoding === null || encoding === 'buffer' ? null : encoding;
  const empty = enc === null ? Buffer.alloc(0) : '';
  return {
    pid: process.pid,
    output: [null, empty, empty],
    stdout: empty,
    stderr: empty,
    status,
    signal: null,
    error: null,
  };
}

/**
 * @param {string[]} nodeArgv arguments after the node binary
 * @param {{ cwd?: string, env?: object, encoding?: string|null }} options
 */
function runNodeSync(nodeArgv, options) {
  options = options || {};
  const classified = classifyArgv(nodeArgv);
  if (classified.kind === 'empty') {
    return emptyResult(0, options.encoding);
  }

  const prev = {
    argv: process.argv,
    cwd: process.cwd(),
    exit: process.exit,
    exitCode: process.exitCode,
    env: process.env,
    stdoutWrite: process.stdout.write,
    stderrWrite: process.stderr.write,
  };

  const outChunks = [];
  const errChunks = [];
  function captureWrite(chunks) {
    return function capturedWrite(chunk, encoding, cb) {
      if (chunk != null && chunk !== undefined) {
        if (Buffer.isBuffer(chunk)) {
          chunks.push(chunk);
        } else {
          const enc = typeof encoding === 'string' ? encoding : 'utf8';
          chunks.push(Buffer.from(String(chunk), enc));
        }
      }
      if (typeof encoding === 'function') encoding();
      else if (typeof cb === 'function') cb();
      return true;
    };
  }
  // spawnSync defaults to pipe stdio — capture nested writes instead of
  // leaking them onto the parent job's stdout (which also left stdout empty
  // in the returned result).
  process.stdout.write = captureWrite(outChunks);
  process.stderr.write = captureWrite(errChunks);

  let status = 0;
  const NestedExit = function NestedExit(code) {
    this.code = Number(code ?? 0) | 0;
    this.__termxNestedExit = true;
  };

  process.exit = function nestedExit(code) {
    throw new NestedExit(code);
  };

  try {
    if (options.cwd) process.chdir(options.cwd);
    if (options.env && typeof options.env === 'object') {
      // Replace env for the duration of the nested script (npm sets a clean env).
      const merged = Object.assign({}, process.env, options.env);
      for (const key of Object.keys(process.env)) {
        if (!Object.prototype.hasOwnProperty.call(options.env, key) &&
            Object.prototype.hasOwnProperty.call(merged, key) === false) {
          delete process.env[key];
        }
      }
      // Prefer assigning keys from options.env onto the live process.env object
      // rather than replacing the binding (Node freezes process.env's identity).
      for (const key of Object.keys(process.env)) {
        if (!Object.prototype.hasOwnProperty.call(options.env, key)) {
          delete process.env[key];
        }
      }
      Object.assign(process.env, options.env);
    }

    process.exitCode = 0;
    if (classified.kind === 'eval') {
      process.argv = ['node', classified.print ? '-p' : '-e', classified.source].concat(classified.rest);
      for (const pre of classified.preloads) require(pre);
      // eslint-disable-next-line no-eval
      const value = eval(classified.source);
      if (classified.print && value !== undefined) {
        process.stdout.write(typeof value === 'string' ? value : require('util').inspect(value));
        process.stdout.write('\n');
      }
    } else {
      const scriptPath = path.isAbsolute(classified.script)
        ? classified.script
        : path.resolve(process.cwd(), classified.script);
      process.argv = ['node', scriptPath].concat(classified.rest);
      for (const pre of classified.preloads) require(pre);
      // Fresh load every time — npm re-runs the same lifecycle script path.
      const resolved = Module._resolveFilename(scriptPath, module, false);
      delete require.cache[resolved];
      Module._load(resolved, module, true);
    }
    status = Number(process.exitCode ?? 0) | 0;
  } catch (err) {
    if (err && err.__termxNestedExit) {
      status = err.code;
    } else if (err && err.termxExitCode !== undefined) {
      // Top-level TermxExit from bootstrap — treat as nested completion, do not
      // finish the outer npm job.
      status = Number(err.termxExitCode) | 0;
    } else {
      const message = String(err && err.stack ? err.stack : err);
      try {
        process.stderr.write(message + '\n');
      } catch (_) {
        /* ignore */
      }
      status = 1;
    }
  } finally {
    process.exit = prev.exit;
    process.argv = prev.argv;
    process.exitCode = prev.exitCode;
    process.stdout.write = prev.stdoutWrite;
    process.stderr.write = prev.stderrWrite;
    try {
      process.chdir(prev.cwd);
    } catch (_) {
      /* ignore */
    }
    // Env: restore keys we can; full restore of deletions is best-effort.
    if (options.env) {
      for (const key of Object.keys(process.env)) {
        if (!Object.prototype.hasOwnProperty.call(prev.env, key)) {
          delete process.env[key];
        }
      }
      Object.assign(process.env, prev.env);
    }
  }

  const enc = options.encoding;
  const encName = enc === undefined || enc === null || enc === 'buffer' ? null : enc;
  const outBuf = Buffer.concat(outChunks);
  const errBuf = Buffer.concat(errChunks);
  const stdout = encName === null ? outBuf : outBuf.toString(encName);
  const stderr = encName === null ? errBuf : errBuf.toString(encName);
  return {
    pid: process.pid,
    output: [null, stdout, stderr],
    stdout,
    stderr,
    status,
    signal: null,
    error: null,
  };
}

module.exports = {
  isNodeBinary,
  classifyArgv,
  runNodeSync,
};
