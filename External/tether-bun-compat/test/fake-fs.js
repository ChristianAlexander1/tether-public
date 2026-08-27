'use strict';

// test/fake-fs.js — a tiny node:fs-compatible in-memory fake used by
// tests. Records call shapes so the "no hardcoding" test can compare
// invocations for two arbitrary names.

const { EventEmitter } = require('node:events');
const { Readable } = require('node:stream');

function makeFakeFs(initial) {
  // files: map path -> { mode, content:Buffer, isDir:bool }
  const files = new Map(initial || []);
  for (const [k, v] of files) {
    if (!v.content) v.content = Buffer.alloc(0);
    if (typeof v.mode !== 'number') v.mode = 0o755;
  }

  // Record calls for spy assertions.
  const calls = { accessSync: [], statSync: [], readFile: [], writeFile: [], mkdir: [], createReadStream: [] };

  function addFile(p, opts) {
    const o = opts || {};
    files.set(p, {
      mode: typeof o.mode === 'number' ? o.mode : 0o755,
      content: Buffer.isBuffer(o.content) ? o.content : Buffer.from(o.content || ''),
      isDir: !!o.isDir,
    });
  }
  function addDir(p) { files.set(p, { isDir: true, mode: 0o755, content: Buffer.alloc(0) }); }
  function has(p) { return files.has(p); }

  const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 };

  function accessSync(p, mode) {
    calls.accessSync.push({ path: p, mode });
    const f = files.get(p);
    if (!f) {
      const err = new Error(`ENOENT: ${p}`);
      err.code = 'ENOENT';
      throw err;
    }
    if (typeof mode === 'number' && (mode & 1)) {
      // executable bit required
      if (f.isDir) {
        const err = new Error(`EACCES: ${p}`);
        err.code = 'EACCES';
        throw err;
      }
      if (!(f.mode & 0o111)) {
        const err = new Error(`EACCES: ${p}`);
        err.code = 'EACCES';
        throw err;
      }
    }
  }

  function statSync(p) {
    calls.statSync.push({ path: p });
    const f = files.get(p);
    if (!f) {
      const err = new Error(`ENOENT: ${p}`);
      err.code = 'ENOENT';
      throw err;
    }
    return {
      size: f.content.length,
      isDirectory: () => !!f.isDir,
      isFile: () => !f.isDir,
      mode: f.mode,
    };
  }

  function readFile(p, encOrCb, maybeCb) {
    let cb = maybeCb || encOrCb;
    let encoding = maybeCb ? encOrCb : null;
    calls.readFile.push({ path: p, encoding });
    const f = files.get(p);
    if (!f) {
      const err = new Error(`ENOENT: ${p}`);
      err.code = 'ENOENT';
      return cb(err);
    }
    if (encoding === 'utf8') cb(null, f.content.toString('utf8'));
    else cb(null, Buffer.from(f.content));
  }

  function writeFile(p, data, cb) {
    calls.writeFile.push({ path: p, length: data && data.length });
    files.set(p, {
      mode: 0o644,
      content: Buffer.isBuffer(data) ? Buffer.from(data) : Buffer.from(data),
      isDir: false,
    });
    cb(null);
  }

  function mkdir(p, opts, cb) {
    calls.mkdir.push({ path: p, opts });
    if (!files.has(p)) {
      files.set(p, { isDir: true, mode: 0o755, content: Buffer.alloc(0) });
    }
    cb(null);
  }

  function createReadStream(p) {
    calls.createReadStream.push({ path: p });
    const f = files.get(p);
    const stream = new Readable({
      read() {
        if (!f) {
          const err = new Error(`ENOENT: ${p}`);
          err.code = 'ENOENT';
          this.destroy(err);
          return;
        }
        this.push(Buffer.from(f.content));
        this.push(null);
      },
    });
    return stream;
  }

  // Async access is used by BunFile.exists(); provide it.
  // Signature matches node: fs.access(path[, mode], callback).
  function access(p, modeOrCb, maybeCb) {
    const cb = maybeCb || modeOrCb;
    const mode = maybeCb ? modeOrCb : 0;
    try { accessSync(p, mode); cb(null); }
    catch (e) { cb(e); }
  }

  return {
    constants,
    addFile, addDir, has, files, calls,
    accessSync, statSync, readFile, writeFile, mkdir, createReadStream, access,
  };
}

module.exports = { makeFakeFs };
