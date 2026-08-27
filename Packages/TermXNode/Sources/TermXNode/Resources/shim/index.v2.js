'use strict';

/**
 * @tether/shim v2 preload — the TJIP/2 entry point.
 *
 * The v1 shim answered TTY questions from `TETHER_INTERACTIVE`, which made
 * every fd look like a terminal whenever any fd was one. v2 derives all of it
 * from the protocol handshake instead, so this entry only has to supply the
 * things that are genuinely outside the protocol:
 *
 *   - the iOS embedding fixes (process.title, HTTP keep-alive) that v1 carried;
 *   - the `os` module shim, which reports real device data and is unrelated to
 *     the job protocol;
 *   - installation of tether-shim-v2 itself, which owns tty / child_process /
 *     stdio / signals.
 *
 * Load order matters: v2 intercepts `Module._load` when its handshake
 * resolves, and it must win for `tty` and `child_process`. We therefore
 * install our `os` mapping first and let v2 layer on top.
 */

const Module = require('module');
const path = require('path');

(function neutralizeProcessTitle() {
  let title = 'node';
  try { title = String(process.title || 'node'); } catch (_) {}
  try { delete process.title; } catch (_) {}
  try {
    Object.defineProperty(process, 'title', {
      configurable: true,
      enumerable: true,
      get() { return title; },
      set(value) { title = String(value); },
    });
  } catch (_) {}
})();

(function disableHttpKeepAlive() {
  try {
    const http = require('http');
    const https = require('https');
    if (http.globalAgent) {
      http.globalAgent.keepAlive = false;
      http.globalAgent.maxSockets = 8;
    }
    if (https.globalAgent) {
      https.globalAgent.keepAlive = false;
      https.globalAgent.maxSockets = 8;
    }
  } catch (_) {}
})();

// Only `os` is mapped here; tty and child_process belong to v2.
const SHIMS = {
  os: path.join(__dirname, 'lib', 'os.js'),
};

const origLoad = Module._load;

function tetherLoadV2(request, parent, isMain) {
  const key = request.startsWith('node:') ? request.slice(5) : request;
  if (Object.prototype.hasOwnProperty.call(SHIMS, key)) {
    return origLoad(SHIMS[key], parent, isMain);
  }
  return origLoad(request, parent, isMain);
}

tetherLoadV2._tetherOriginalLoad = origLoad;
tetherLoadV2._tetherPatched = true;

if (!origLoad._tetherPatched) {
  Module._load = tetherLoadV2;
}

const shimV2 = require('./v2/lib/index.js');

// One-process-per-job lane (host node): TETHER_IPC_SOCK is in the environment
// at spawn, so requiring the shim auto-installs right here. Persistent-engine
// lane (nodejs-mobile): no socket exists at preload time and every job gets a
// fresh one, so bootstrap.js opens a session per job via beginSession() and
// closes it in its reply path via endSession().

module.exports = {
  os: require('./lib/os'),
  v2: shimV2,
  ready: shimV2.ready,
  install: shimV2.install,
  restore() {
    Module._load = origLoad;
  },
};
