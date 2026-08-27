'use strict';

// lib/file.js — Bun.file / Bun.write over an injected node:fs-compatible
// object. Lazy BunFile shape; no special-case file names anywhere.

const path = require('node:path');
const { Readable } = require('node:stream');

// Minimal extension -> MIME table. This is a data table, not logic;
// adding an extension means adding one row here.
const MIME_BY_EXT = {
  '.txt': 'text/plain;charset=utf-8',
  '.html': 'text/html;charset=utf-8',
  '.htm': 'text/html;charset=utf-8',
  '.css': 'text/css;charset=utf-8',
  '.js': 'text/javascript;charset=utf-8',
  '.mjs': 'text/javascript;charset=utf-8',
  '.cjs': 'text/javascript;charset=utf-8',
  '.json': 'application/json;charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.mp3': 'audio/mpeg',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
};
const DEFAULT_MIME = 'application/octet-stream';

function mimeFor(p) {
  const ext = path.extname(p).toLowerCase();
  return MIME_BY_EXT[ext] || DEFAULT_MIME;
}

function toError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function createBunFile(fs, filePath) {
  let didStat = false;
  let stat = null;
  let statErr = null;

  function ensureStat() {
    if (didStat) return;
    didStat = true;
    try {
      stat = fs.statSync(filePath);
    } catch (e) {
      statErr = e;
    }
  }

  const file = {
    get name() { return filePath; },
    get type() { return mimeFor(filePath); },
    get size() {
      ensureStat();
      if (statErr || !stat) return 0;
      return stat.size;
    },
    exists() {
      return new Promise((resolve) => {
        fs.access(filePath, (err) => resolve(!err));
      });
    },
    text() {
      return new Promise((resolve, reject) => {
        fs.readFile(filePath, 'utf8', (err, data) => {
          if (err) return reject(toError(err.code || 'ENOENT', err.message));
          resolve(data);
        });
      });
    },
    arrayBuffer() {
      return new Promise((resolve, reject) => {
        fs.readFile(filePath, (err, data) => {
          if (err) return reject(toError(err.code || 'ENOENT', err.message));
          // data is a Buffer; copy into a fresh ArrayBuffer to match
          // Bun's detached-buffer semantics.
          const ab = new ArrayBuffer(data.length);
          new Uint8Array(ab).set(data);
          resolve(ab);
        });
      });
    },
    bytes() {
      return new Promise((resolve, reject) => {
        fs.readFile(filePath, (err, data) => {
          if (err) return reject(toError(err.code || 'ENOENT', err.message));
          resolve(new Uint8Array(data));
        });
      });
    },
    json() {
      return this.text().then((t) => JSON.parse(t));
    },
    stream() {
      // Returns a WHATWG ReadableStream of Uint8Array chunks. We always
      // open the node readable lazily (so missing files error during
      // read rather than construction, consistent with Bun).
      const nodeReadable = fs.createReadStream(filePath);
      return Readable.toWeb(nodeReadable);
    },
    // Writer/Blob-like surfaces Bun exposes but we don't fully support
    // are intentionally omitted; Fidelity notes lists them.
  };
  return file;
}

function asBuffer(data) {
  if (typeof data === 'string') return Buffer.from(data, 'utf8');
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  }
  // BunFile-like: read its bytes.
  if (data && typeof data.bytes === 'function') {
    return data.bytes().then((u8) => Buffer.from(u8));
  }
  return Promise.reject(new TypeError('Unsupported data type for Bun.write'));
}

function createFileApi(fs) {
  function bunFile(filePath) {
    if (typeof filePath !== 'string') {
      // Bun.file accepts URL/string; we only support string here.
      throw new TypeError('Bun.file: path must be a string');
    }
    return createBunFile(fs, filePath);
  }

  function write(dest, data) {
    return Promise.resolve().then(() => {
      const destPath = (dest && typeof dest === 'object' && typeof dest.name === 'string')
        ? dest.name
        : dest;
      if (typeof destPath !== 'string') {
        throw new TypeError('Bun.write: destination must be a path or BunFile');
      }
      return Promise.resolve(asBuffer(data)).then((buf) => {
        return new Promise((resolve, reject) => {
          const dir = path.dirname(destPath);
          fs.mkdir(dir, { recursive: true }, (mkErr) => {
            if (mkErr && mkErr.code !== 'EEXIST') return reject(mkErr);
            fs.writeFile(destPath, buf, (wErr) => {
              if (wErr) return reject(wErr);
              resolve(buf.length);
            });
          });
        });
      });
    });
  }

  return { file: bunFile, write };
}

module.exports = { createFileApi, mimeFor, MIME_BY_EXT, DEFAULT_MIME };
