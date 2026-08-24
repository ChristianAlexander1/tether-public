'use strict';

/**
 * @tether/shim — preload for nodejs-mobile and host Node tests.
 * Patches child_process / os / tty; keeps iOS embedding fixes from TermX bootstrap.
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

const SHIMS = {
  child_process: path.join(__dirname, 'lib', 'child_process.js'),
  os: path.join(__dirname, 'lib', 'os.js'),
  tty: path.join(__dirname, 'lib', 'tty.js'),
};

const origLoad = Module._load;

function tetherLoad(request, parent, isMain) {
  const key = request.startsWith('node:') ? request.slice(5) : request;
  if (Object.prototype.hasOwnProperty.call(SHIMS, key)) {
    return origLoad(SHIMS[key], parent, isMain);
  }
  return origLoad(request, parent, isMain);
}

tetherLoad._tetherOriginalLoad = origLoad;
tetherLoad._tetherPatched = true;

if (!origLoad._tetherPatched) {
  Module._load = tetherLoad;
}

module.exports = {
  child_process: require('./lib/child_process'),
  os: require('./lib/os'),
  tty: require('./lib/tty'),
  ipc: require('./lib/ipc'),
  restore() {
    Module._load = origLoad;
  },
};
