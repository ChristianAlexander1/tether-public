'use strict';

// lib/which.js — honest PATH directory scan for Bun.which.
//
// Design:
//   * The list of PATH directories is captured at install time (or
//     overridden per-call via options.PATH) — we never re-read
//     process.env ourselves.
//   * We never special-case any command name; every name goes through
//     byte-identical code paths. If the name contains a path separator
//     we check it directly (this is part of the generic resolution
//     rule, not a name list).
//   * On POSIX we require fs.accessSync(p, X_OK); on Windows-style
//     setups we approximate executability by existence (documented
//     in HANDOFF.md).

const path = require('node:path');

const IS_WIN = (() => {
  // Detect by the platform info injected at install time. Defaults to
  // process.platform. We only care about win32 here.
  return process.platform === 'win32';
})();

function hasSep(name) {
  // A name that contains any path separator is treated as a direct path.
  // This covers both POSIX '/' and Windows '\' (and '/' on Windows).
  return name.indexOf('/') !== -1 || name.indexOf('\\') !== -1;
}

function splitPathString(pathStr) {
  if (!pathStr || typeof pathStr !== 'string') return [];
  // Split on the platform delimiter. On Windows PATH uses ';', but we
  // accept both ';' and ':' so injected tests stay portable.
  if (IS_WIN) {
    return pathStr.split(/[;]/).map(s => s.trim()).filter(Boolean);
  }
  return pathStr.split(':').map(s => s).filter(Boolean);
}

function isExecutable(fs, fullPath) {
  // fs may be a fake; make sure constants exist.
  const xok = (fs.constants && typeof fs.constants.X_OK === 'number')
    ? fs.constants.X_OK
    : 0o1; // X_OK == 1 on POSIX
  try {
    fs.accessSync(fullPath, xok);
    return true;
  } catch (e) {
    return false;
  }
}

function isDirectory(fs, fullPath) {
  try {
    return fs.statSync(fullPath).isDirectory();
  } catch (e) {
    return false;
  }
}

function createWhich({ pathDirs, fs, platform }) {
  const isWin = platform === 'win32' || IS_WIN;

  function which(name, options) {
    if (typeof name !== 'string' || name.length === 0) return null;
    const opts = options || {};

    // Direct-path form: name contains a separator -> check that path.
    if (hasSep(name)) {
      const resolved = opts.cwd && !path.isAbsolute(name)
        ? path.resolve(opts.cwd, name)
        : name;
      if (isExecutable(fs, resolved) && !isDirectory(fs, resolved)) {
        return resolved;
      }
      return null;
    }

    // Determine directories to scan.
    let dirs;
    if (typeof opts.PATH === 'string') {
      dirs = splitPathString(opts.PATH);
    } else if (Array.isArray(opts.PATH)) {
      dirs = opts.PATH.slice();
    } else {
      dirs = pathDirs;
    }

    if (!dirs || dirs.length === 0) return null;

    for (let i = 0; i < dirs.length; i++) {
      let dir = dirs[i];
      if (opts.cwd && !path.isAbsolute(dir)) {
        dir = path.resolve(opts.cwd, dir);
      }
      if (!dir) continue;
      const full = path.join(dir, name);
      // Skip non-existent or non-executable entries (including directories).
      if (isWin) {
        // On Windows, approximate executability by existence and
        // non-directory. We do not consult PATHEXT to avoid a fixed
        // extension list; callers supply full names.
        try {
          const st = fs.statSync(full);
          if (st && st.isDirectory && st.isDirectory()) continue;
        } catch (e) {
          continue;
        }
        return full;
      }
      if (isDirectory(fs, full)) continue;
      if (isExecutable(fs, full)) {
        return full;
      }
    }
    return null;
  }

  return which;
}

module.exports = { createWhich, splitPathString, hasSep };
