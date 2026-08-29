'use strict';

// Rewrite guest `/work` paths onto the Darwin workspace the host job actually
// has. The Alpine shell mounts the selected iOS folder at `/work`; host-run
// Node sees the real folder via TETHER_HOST_CWD. Tools that still emit
// absolute `/work/...` paths (because PWD in the guest was `/work`) would
// otherwise fail with ENOENT on a path that does not exist on Darwin.

const fs = require('node:fs');
const path = require('node:path');

let installed = false;

function mapWorkPath(value) {
  const host = process.env.TETHER_HOST_CWD;
  if (!host || typeof value !== 'string') return value;
  if (value === '/work') return host;
  if (value.startsWith('/work/')) return host + value.slice('/work'.length);
  return value;
}

function wrapFsMethod(name) {
  const orig = fs[name];
  if (typeof orig !== 'function') return;
  fs[name] = function mapped(p, ...rest) {
    return orig.call(this, mapWorkPath(p), ...rest);
  };
}

function attach() {
  if (installed) return;
  if (!process.env.TETHER_HOST_CWD) return;
  installed = true;

  const origResolve = path.resolve;
  path.resolve = function mappedResolve(...args) {
    return mapWorkPath(origResolve.apply(this, args));
  };

  const origChdir = process.chdir.bind(process);
  process.chdir = function mappedChdir(dir) {
    return origChdir(mapWorkPath(dir));
  };

  for (const name of [
    'access',
    'accessSync',
    'appendFile',
    'appendFileSync',
    'chmod',
    'chmodSync',
    'copyFile',
    'copyFileSync',
    'createReadStream',
    'createWriteStream',
    'existsSync',
    'lstat',
    'lstatSync',
    'mkdir',
    'mkdirSync',
    'open',
    'openSync',
    'readFile',
    'readFileSync',
    'readdir',
    'readdirSync',
    'realpath',
    'realpathSync',
    'rename',
    'renameSync',
    'rm',
    'rmSync',
    'rmdir',
    'rmdirSync',
    'stat',
    'statSync',
    'truncate',
    'truncateSync',
    'unlink',
    'unlinkSync',
    'writeFile',
    'writeFileSync',
  ]) {
    wrapFsMethod(name);
  }
}

module.exports = { attach, mapWorkPath };
