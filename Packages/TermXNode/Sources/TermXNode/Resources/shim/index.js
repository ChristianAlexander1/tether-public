'use strict';

/**
 * termx-shim: installs the overrides for the Node module system.
 *
 * Preloaded by the app with `node --require /path/to/termx-shim/index.js`.
 * Patching Module._load means that any `require('child_process')`,
 * `require('node:child_process')`, `require('os')`, `require('node:os')`,
 * `require('tty')` or `require('node:tty')` anywhere in npm / any package
 * resolves to this package's implementations, regardless of how the requiring
 * module spells the request.
 */

const Module = require('module');

// iOS embedding: Node shares the app process. libuv's uv_set_process_title
// (reached via `process.title = …`) uses argv bookkeeping that node_start
// does not set up the same way as a standalone binary, and SIGTRAPs the
// process. Replace the native accessor with an in-memory title so npm and
// other CLIs keep their real behavior without touching libuv.
(function neutralizeProcessTitle() {
  let title = 'node';
  try {
    title = String(process.title || 'node');
  } catch (_) {
    /* ignore */
  }
  try {
    delete process.title;
  } catch (_) {
    /* ignore */
  }
  try {
    Object.defineProperty(process, 'title', {
      configurable: true,
      enumerable: true,
      get() {
        return title;
      },
      set(value) {
        title = String(value);
      },
    });
  } catch (_) {
    /* last resort: leave native accessor; title writes may still crash */
  }
})();

// iOS reports process.platform === 'ios', which breaks npm optionalDependencies
// and packages that key on darwin/linux/win32 (Claude Code, sharp, …). The OS
// is Darwin underneath; expose that so the Node package ecosystem resolves
// the same way it does on a Mac terminal. os.platform() already returns
// 'darwin' via lib/os.js — keep process.platform in sync.
(function reportDarwinPlatform() {
  try {
    delete process.platform;
  } catch (_) {
    /* ignore */
  }
  try {
    Object.defineProperty(process, 'platform', {
      configurable: true,
      enumerable: true,
      get() {
        return 'darwin';
      },
      set() {
        /* immutable for package compatibility */
      },
    });
  } catch (_) {
    try {
      process.platform = 'darwin';
    } catch (_) {
      /* leave native 'ios' if the engine forbids override */
    }
  }
})();

// Keep-alive sockets hold the event loop open after short CLIs (npm --version)
// finish, so the next job never starts cleanly. Disable keep-alive on the
// legacy Agents. Do not replace undici's global dispatcher — a custom Agent
// with tiny keepAlive timeouts caused CheckImmediate spin loops on the
// following npm install in this persistent engine.
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
  } catch (_) {
    /* ignore */
  }
})();

const overrides = {
  child_process: require('./lib/child_process'),
  os: require('./lib/os'),
  tty: require('./lib/tty'),
};

const originalLoad = Module._load;

function match(request) {
  if (typeof request !== 'string') return null;
  // Tolerate both 'child_process' and 'node:child_process' spellings.
  const bare = request.startsWith('node:') ? request.slice('node:'.length) : request;
  return Object.prototype.hasOwnProperty.call(overrides, bare)
    ? overrides[bare]
    : null;
}

Module._load = function patchedLoad(request, parent, isMain) {
  const hit = match(request);
  if (hit) return hit;
  return originalLoad.apply(this, arguments);
};

module.exports = {
  overrides,
  restore() {
    Module._load = originalLoad;
  },
};
