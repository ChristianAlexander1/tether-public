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
