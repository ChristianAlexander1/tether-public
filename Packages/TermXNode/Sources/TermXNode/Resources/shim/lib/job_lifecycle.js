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
/** @type {Map<string | symbol, Function[]> | null} */
let savedProcessListeners = null;

/** Snapshot process listeners before a CLI mutates the persistent Node process. */
function beginJob() {
  savedProcessListeners = new Map();
  for (const event of process.eventNames()) {
    savedProcessListeners.set(event, process.rawListeners(event).slice());
  }
}

/**
 * Remove listeners installed by the completed CLI and restore the engine's
 * exact pre-job listener set, including once-listener semantics.
 */
function restoreProcessListeners() {
  if (!savedProcessListeners) return;
  const events = new Set([...process.eventNames(), ...savedProcessListeners.keys()]);
  for (const event of events) {
    try { process.removeAllListeners(event); } catch (_) { /* ignore */ }
    for (const listener of savedProcessListeners.get(event) || []) {
      try {
        if (typeof listener.listener === 'function') {
          process.once(event, listener.listener);
        } else {
          process.on(event, listener);
        }
      } catch (_) { /* ignore */ }
    }
  }
  savedProcessListeners = null;
}

function bindStdinFromJob(job) {
  savedStdin = process.stdin;
  stdinOverride = null;

  if (job.stdinData) {
    const buf = Buffer.from(String(job.stdinData), 'base64');
    const stream = new PassThrough();
    stream.end(buf);
    stdinOverride = stream;
  }
  // Interactive TTY stdin is a live Readable installed by the v2 shim from
  // tty.stdin pushes. Never pass the PTY slave fd to nodejs-mobile (it fails
  // to poll borrowed fds after npm) and never end that stream on idle.

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

/**
 * Cloud SDK graphs (Vertex/AWS IMDS) probe link-local metadata at import time.
 * nodejs-mobile does not time those sockets or getaddrinfo out, which
 * deadlocks ESM `import()` while the event loop still runs timers.
 */
function rejectInstanceMetadata() {
  if (rejectInstanceMetadata._installed) return;
  rejectInstanceMetadata._installed = true;
  function isMetadataHost(host) {
    let h = String(host || '').trim().toLowerCase();
    h = h.replace(/^\[(.+)\]$/, '$1');
    const colons = (h.match(/:/g) || []).length;
    if (colons === 1 && !h.includes('::')) h = h.split(':')[0];
    return h === '169.254.169.254' || h === '169.254.170.2'
      || h === 'fd00:ec2::254' || h === 'metadata.google.internal';
  }
  function hostOf(options) {
    if (typeof options === 'string') {
      try { return require('url').parse(options).hostname || ''; } catch (_) { return ''; }
    }
    if (!options || typeof options !== 'object') return '';
    return options.hostname || options.host || '';
  }
  function metaErr(host) {
    return Object.assign(new Error('tether: instance metadata is not available'), {
      code: 'ENOTFOUND',
      errno: 'ENOTFOUND',
      syscall: 'getaddrinfo',
      hostname: host,
    });
  }
  function rejectReq(host) {
    const { EventEmitter } = require('events');
    const req = new EventEmitter();
    req.aborted = false;
    req.destroyed = false;
    req.destroy = function destroy(err) {
      this.destroyed = true;
      this.emit('error', err || new Error('destroyed'));
      return this;
    };
    req.abort = function abort() { this.aborted = true; this.destroy(); return this; };
    req.end = function end() { return this; };
    req.write = function write() { return true; };
    req.setTimeout = function setTimeoutMs() { return this; };
    req.setHeader = function setHeader() {};
    req.getHeader = function getHeader() { return undefined; };
    req.removeHeader = function removeHeader() {};
    req.flushHeaders = function flushHeaders() {};
    process.nextTick(() => req.emit('error', metaErr(host)));
    return req;
  }
  function patchHttp(mod) {
    if (!mod || typeof mod.request !== 'function' || mod.request.__tetherMeta) return;
    const origReq = mod.request;
    const origGet = typeof mod.get === 'function' ? mod.get : null;
    function wrappedRequest(options, cb) {
      const host = hostOf(options);
      if (isMetadataHost(host)) return rejectReq(host);
      return origReq.apply(this, arguments);
    }
    wrappedRequest.__tetherMeta = true;
    mod.request = wrappedRequest;
    if (origGet) {
      mod.get = function wrappedGet(options, cb) {
        const req = wrappedRequest.apply(this, arguments);
        if (req && typeof req.end === 'function') req.end();
        return req;
      };
    }
  }
  function patchDns(dns) {
    if (!dns || typeof dns.lookup !== 'function' || dns.lookup.__tetherMeta) return;
    const origLookup = dns.lookup;
    function wrappedLookup(hostname, options, callback) {
      const host = String(hostname || '');
      const cb = typeof options === 'function' ? options : callback;
      if (isMetadataHost(host)) {
        if (typeof cb === 'function') process.nextTick(() => cb(metaErr(host)));
        return;
      }
      return origLookup.apply(this, arguments);
    }
    wrappedLookup.__tetherMeta = true;
    dns.lookup = wrappedLookup;
    if (dns.promises && typeof dns.promises.lookup === 'function' && !dns.promises.lookup.__tetherMeta) {
      const origProm = dns.promises.lookup.bind(dns.promises);
      dns.promises.lookup = function wrappedPromLookup(hostname, options) {
        const host = String(hostname || '');
        if (isMetadataHost(host)) {
          return Promise.reject(metaErr(host));
        }
        return origProm(hostname, options);
      };
      dns.promises.lookup.__tetherMeta = true;
    }
  }
  function netHost(args) {
    const a = args[0];
    if (a && typeof a === 'object') return a.host || a.hostname || '';
    if (typeof a === 'number') return typeof args[1] === 'string' ? args[1] : '';
    return '';
  }
  function patchNet(net) {
    if (!net || typeof net.connect !== 'function' || net.connect.__tetherMeta) return;
    const origConnect = net.connect;
    const origCreate = net.createConnection;
    function wrappedConnect() {
      const host = netHost(arguments);
      if (isMetadataHost(host)) {
        const { Socket } = net;
        const sock = new Socket();
        process.nextTick(() => sock.destroy(metaErr(host)));
        return sock;
      }
      return origConnect.apply(this, arguments);
    }
    wrappedConnect.__tetherMeta = true;
    net.connect = wrappedConnect;
    if (typeof origCreate === 'function') net.createConnection = wrappedConnect;
  }
  const http = require('http');
  const https = require('https');
  const dns = require('dns');
  const net = require('net');
  patchHttp(http);
  patchHttp(https);
  patchDns(dns);
  patchNet(net);
  try {
    const Module = require('module');
    const raw = Module._load && Module._load._tetherOriginalLoad;
    if (typeof raw === 'function') {
      patchHttp(raw('http', module, false));
      patchHttp(raw('https', module, false));
      patchDns(raw('dns', module, false));
      patchNet(raw('net', module, false));
    }
    if (typeof Module.syncBuiltinESMExports === 'function') Module.syncBuiltinESMExports();
  } catch (_) { /* launcher also republishes these cells */ }
  // undici keeps its own connect path, so reject metadata hosts at the fetch layer too.
  const origFetch = typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : null;
  if (origFetch && !globalThis.fetch.__tetherMeta) {
    function wrappedFetch(input, init) {
      const raw = typeof input === 'string' ? input : (input && (input.url || input.href)) || '';
      let host = '';
      try { host = new URL(String(raw)).hostname; } catch (_) { /* relative or opaque */ }
      if (host && isMetadataHost(host)) return Promise.reject(metaErr(host));
      return origFetch.apply(this, arguments);
    }
    wrappedFetch.__tetherMeta = true;
    globalThis.fetch = wrappedFetch;
  }
}

/** Push each stdout/stderr write to the PTY immediately (embedded Node buffers otherwise). */
function enableLiveOutput() {
  if (enableLiveOutput._installed) return;
  enableLiveOutput._installed = true;
  rejectInstanceMetadata();
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

function finishJob(keepRef, ipc) {
  silenceEventLoopStorm();
  teardownJob(keepRef);
  restoreStdin();
  restoreProcessListeners();
  try { if (ipc && typeof ipc.clearTransport === 'function') ipc.clearTransport(); } catch (_) { /* ignore */ }
}

try { rejectInstanceMetadata(); } catch (_) { /* best-effort; enableLiveOutput retries */ }

module.exports = {
  beginJob,
  bindStdinFromJob,
  restoreStdin,
  restoreProcessListeners,
  teardownJob,
  silenceEventLoopStorm,
  finishJob,
  enableLiveOutput,
  rejectInstanceMetadata,
};
