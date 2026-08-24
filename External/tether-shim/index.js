'use strict';

/**
 * --require entry: patch Module._load so `require('child_process')`,
 * `require('os')`, and `require('tty')` resolve to the Tether shims.
 */

const Module = require('module');
const path = require('path');

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
};
