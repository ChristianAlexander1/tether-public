'use strict';

// lib/index.js — installBunGlobal(options)
//
// Installs a faithful subset of the Bun global onto globalThis. All
// platform-specific machinery (fs, child_process, PATH, env, platform) is
// injected so tests run deterministically on any machine with plain Node.

const fsNode = require('node:fs');
const cpNode = require('node:child_process');
const path = require('node:path');

const { createWhich } = require('./which');
const { createFileApi } = require('./file');
const { createSpawnApi } = require('./spawn');
const { createUtil } = require('./util');

function defaultPathDirs() {
  const p = process.env.PATH || '';
  if (process.platform === 'win32') {
    return p.split(';').map(s => s.trim()).filter(Boolean);
  }
  return p.split(':').filter(Boolean);
}

function installBunGlobal(options) {
  const opts = options || {};

  if (globalThis.Bun && opts.force !== true) {
    const err = new Error('globalThis.Bun already exists (pass {force:true} to replace)');
    err.code = 'EEXIST';
    throw err;
  }

  // Capture all injected dependencies at install time — never re-read
  // process.env or process.platform later.
  const platformInfo = opts.platformInfo || {
    platform: process.platform,
    arch: process.arch,
  };
  const pathDirs = opts.pathDirs || defaultPathDirs();
  const fs = opts.fs || fsNode;
  const spawnImpl = opts.spawnImpl || cpNode;
  const env = opts.env || process.env;
  const version = opts.version || '1.1.0-tether';

  const which = createWhich({
    pathDirs,
    fs,
    platform: platformInfo.platform,
  });
  const fileApi = createFileApi(fs);
  const spawnApi = createSpawnApi(spawnImpl);
  const utilApi = createUtil({ env, version, platformInfo, clock: opts.clock });

  const Bun = {
    which,
    file: fileApi.file,
    write: fileApi.write,
    spawn: spawnApi.spawn,
    spawnSync: spawnApi.spawnSync,
    sleep: utilApi.sleep,
    sleepSync: utilApi.sleepSync,
    env: utilApi.env,
    version: utilApi.version,
    revision: utilApi.revision,
    stringWidth: utilApi.stringWidth,
    deepEquals: utilApi.deepEquals,
    hash: utilApi.hash,
    randomUUIDv7: utilApi.randomUUIDv7,
    fileURLToPath: utilApi.fileURLToPath,
    pathToFileURL: utilApi.pathToFileURL,
    gc: utilApi.gc,
    main: utilApi.main,
    nanoseconds: utilApi.nanoseconds,
    platform: utilApi.platform,
    // Non-normative: mark the shim so host code can detect it.
    [Symbol.for('tether-bun-compat')]: true,
  };

  Object.defineProperty(globalThis, 'Bun', {
    value: Bun,
    configurable: true,
    writable: true,
    enumerable: true,
  });

  return Bun;
}

module.exports = { installBunGlobal };
module.exports.installBunGlobal = installBunGlobal;
module.exports.default = installBunGlobal;
