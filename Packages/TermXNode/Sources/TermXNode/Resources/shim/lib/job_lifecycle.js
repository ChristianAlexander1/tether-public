'use strict';

/**
 * Job lifecycle for the persistent nodejs-mobile engine.
 *
 * Each shell command is a job with a clean stdin binding and a mandatory teardown
 * so npm/CLI leftovers (handles, beforeExit listeners, HTTP agents) cannot leak
 * into the next job and peg CPU.
 */

const { PassThrough } = require('stream');

/** @type {import('stream').Stream | null} */
let stdinOverride = null;
/** @type {import('stream').Stream | null} */
let savedStdin = null;

function bindStdinFromJob(job) {
  savedStdin = process.stdin;
  stdinOverride = null;

  if (job.stdinData) {
    const buf = Buffer.from(String(job.stdinData), 'base64');
    const stream = new PassThrough();
    stream.end(buf);
    stdinOverride = stream;
  } else {
    const fd = Number(job.stdinFD ?? -1);
    if (fd >= 0) {
      // Legacy path: fd still attached (host / tests). Prefer Swift slurp in production.
      const fs = require('fs');
      const stream = new PassThrough();
      const chunk = Buffer.alloc(64 * 1024);
      try {
        for (;;) {
          const n = fs.readSync(fd, chunk, 0, chunk.length, null);
          if (!n) break;
          stream.write(chunk.subarray(0, n));
        }
      } catch (_) {
        /* ignore */
      }
      stream.end();
      stdinOverride = stream;
    }
  }

  if (!stdinOverride) return;

  try {
    Object.defineProperty(process, 'stdin', {
      configurable: true,
      enumerable: true,
      get() { return stdinOverride; },
      set() { /* ignore */ },
    });
  } catch (_) {
    try { process.stdin = stdinOverride; } catch (_) { /* ignore */ }
  }
}

function restoreStdin() {
  if (!stdinOverride) return;
  try { stdinOverride.removeAllListeners(); } catch (_) { /* ignore */ }
  try { stdinOverride.destroy(); } catch (_) { /* ignore */ }
  stdinOverride = null;
  if (!savedStdin) return;
  try {
    Object.defineProperty(process, 'stdin', {
      value: savedStdin,
      configurable: true,
      enumerable: true,
      writable: true,
    });
  } catch (_) {
    try { process.stdin = savedStdin; } catch (_) { /* ignore */ }
  }
  savedStdin = null;
}

function shouldTeardownHandle(handle, keepRef) {
  if (!handle || handle === keepRef) return false;
  if (handle === process.stdin || handle === process.stdout || handle === process.stderr) {
    return false;
  }
  // Never close the persistent job pipes — reply-before-teardown is the primary
  // fix, but keep these FDs alive if they appear in _getActiveHandles.
  try {
    const replyFD = Number(process.env.TERMX_JOB_REPLY_FD ?? -1);
    const jobFD = Number(process.env.TERMX_JOB_FD ?? -1);
    const fd = typeof handle.fd === 'number' ? handle.fd : -1;
    if (fd >= 0 && (fd === replyFD || fd === jobFD)) return false;
  } catch (_) { /* ignore */ }
  const ctor = handle.constructor && handle.constructor.name;
  if (ctor === 'WriteStream' || ctor === 'ReadStream' || ctor === 'TTY') return false;
  return true;
}

/**
 * Close handles and listeners left by npm / short CLIs. `keepRef` is the job intake
 * socket — must stay open between jobs. Stdio streams are never destroyed.
 */
function teardownJob(keepRef) {
  try {
    process.removeAllListeners('beforeExit');
  } catch (_) { /* ignore */ }

  try {
    const http = require('http');
    const https = require('https');
    if (http.globalAgent && typeof http.globalAgent.destroy === 'function') {
      http.globalAgent.destroy();
    }
    if (https.globalAgent && typeof https.globalAgent.destroy === 'function') {
      https.globalAgent.destroy();
    }
  } catch (_) { /* ignore */ }

  if (typeof process._getActiveHandles === 'function') {
    for (const handle of process._getActiveHandles()) {
      if (!shouldTeardownHandle(handle, keepRef)) continue;
      const ctor = handle.constructor && handle.constructor.name;
      if (ctor === 'Timeout' || ctor === 'Immediate' || ctor === 'Timer') {
        try {
          if (typeof handle.close === 'function') handle.close();
          else if (typeof handle.unref === 'function') handle.unref();
        } catch (_) { /* ignore */ }
        continue;
      }
      try {
        if (typeof handle.unref === 'function') handle.unref();
        if (typeof handle.close === 'function') handle.close();
        else if (typeof handle.destroy === 'function') handle.destroy();
      } catch (_) { /* ignore */ }
    }
  }

  if (typeof process._getActiveRequests === 'function') {
    for (const req of process._getActiveRequests()) {
      try {
        if (typeof req.abort === 'function') req.abort();
      } catch (_) { /* ignore */ }
    }
  }
}

/** Push each stdout/stderr write to the PTY immediately (embedded Node buffers otherwise). */
function enableLiveOutput() {
  if (enableLiveOutput._installed) return;
  enableLiveOutput._installed = true;
  const fs = require('fs');
  function wrap(stream, fd) {
    const orig = stream.write.bind(stream);
    stream.write = function wrappedWrite(chunk, encoding, cb) {
      const ret = orig(chunk, encoding, typeof encoding === 'function' ? encoding : cb);
      try { fs.fsyncSync(fd); } catch (_) { /* ignore */ }
      return ret;
    };
  }
  wrap(process.stdout, 1);
  wrap(process.stderr, 2);
}

/**
 * npm sometimes queues unbounded setImmediate/nextTick work after trapped exit.
 * Drop one timer turn of stray work so libuv can poll the job intake fd again.
 */
function silenceEventLoopStorm() {
  const origImm = global.setImmediate;
  const origTick = process.nextTick;
  if (typeof origImm !== 'function' || typeof origTick !== 'function') return;
  if (origImm.__termxSilencing) return;
  let live = true;
  function patchedImm(fn, ...args) {
    if (!live) return origImm(fn, ...args);
    return { __termxDropped: true };
  }
  function patchedTick(fn, ...args) {
    if (!live) return origTick(fn, ...args);
  }
  patchedImm.__termxSilencing = true;
  global.setImmediate = patchedImm;
  process.nextTick = patchedTick;
  setTimeout(() => {
    live = false;
    if (global.setImmediate === patchedImm) global.setImmediate = origImm;
    if (process.nextTick === patchedTick) process.nextTick = origTick;
  }, 0);
}

/** ora/npm progress spinners hide the cursor and redraw with \\r — reset on job end. */
function clearProgressLine() {
  try {
    process.stderr.write('\x1b[?25h\x1b[2K\r');
  } catch (_) { /* ignore */ }
  try {
    process.stdout.write('\x1b[2K\r');
  } catch (_) { /* ignore */ }
}

function finishJob(keepRef, ipc) {
  if ((process.env.TETHER_INTERACTIVE ?? process.env.TERMX_INTERACTIVE) === '1') {
    clearProgressLine();
  }
  silenceEventLoopStorm();
  teardownJob(keepRef);
  restoreStdin();
  try { ipc.clearTransport(); } catch (_) { /* ignore */ }
}

module.exports = {
  bindStdinFromJob,
  restoreStdin,
  teardownJob,
  silenceEventLoopStorm,
  finishJob,
  enableLiveOutput,
};
