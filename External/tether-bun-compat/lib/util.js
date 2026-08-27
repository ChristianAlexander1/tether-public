'use strict';

// lib/util.js — assorted Bun.* utilities: sleep, env, version,
// stringWidth, deepEquals, hash (FNV-1a stand-in), randomUUIDv7,
// fileURLToPath/pathToFileURL, gc, main.
//
// No npm dependencies. Unicode width ranges are a compact data table.

const url = require('node:url');
const { TextEncoder } = require('node:util');

// ---------------------------------------------------------------------------
// Unicode width tables
// ---------------------------------------------------------------------------

// Zero-width codepoints: combining marks, ZWJ/ZWNJ/ZWSP, variation selectors.
const ZERO_WIDTH_RANGES = [
  [0x0300, 0x036F], // combining diacritical marks
  [0x200B, 0x200D], // ZWSP, ZWNJ, ZWJ
  [0xFE00, 0xFE0F], // variation selectors
];

// East-Asian Wide / Fullwidth and emoji ranges (display width 2).
const WIDE_RANGES = [
  [0x1100, 0x115F], // Hangul Jamo
  [0x2E80, 0xA4CF], // CJK Radicals .. Yi Radicals
  [0xAC00, 0xD7A3], // Hangul Syllables
  [0xF900, 0xFAFF], // CJK Compatibility Ideographs
  [0xFF00, 0xFF60], // Fullwidth Forms
  [0xFFE0, 0xFFE6], // Fullwidth signs
  [0x1F300, 0x1FAFF], // emoji & symbols
];

function inRanges(cp, ranges) {
  for (let i = 0; i < ranges.length; i++) {
    if (cp >= ranges[i][0] && cp <= ranges[i][1]) return true;
  }
  return false;
}

// ANSI escape sequences: CSI (and a generous OSC/ESC sequence) stripped
// before measuring. Pattern covers the common CSI form.
const ANSI_RE = /[\u001b\u009b](?:\][^\u0007]*(?:\u0007|\u001b\\)|\[[0-?]*[ -/]*[@-~]|[ -/]*[@-~])/g;

function stringWidth(str) {
  if (typeof str !== 'string') return 0;
  if (str.length === 0) return 0;
  const stripped = str.replace(ANSI_RE, '');
  let width = 0;
  for (const ch of stripped) {
    const cp = ch.codePointAt(0);
    if (cp < 0x20) {
      // C0 control: treat as 0 width (newlines/tabs are not measured).
      continue;
    }
    if (inRanges(cp, ZERO_WIDTH_RANGES)) continue;
    if (inRanges(cp, WIDE_RANGES)) { width += 2; continue; }
    width += 1;
  }
  return width;
}

// ---------------------------------------------------------------------------
// deepEquals with cycle tracking
// ---------------------------------------------------------------------------

function getTag(value) {
  return Object.prototype.toString.call(value);
}

function isTypedArray(value) {
  return ArrayBuffer.isView(value) && !(value instanceof DataView);
}

function deepEquals(a, b, strict) {
  const seen = new Map(); // a -> Set of b's already compared

  function eq(x, y) {
    if (Object.is(x, y)) return true;
    if (x === null || y === null) return x === y;
    if (typeof x !== 'object' || typeof y !== 'object') {
      // NaN
      if (typeof x === 'number' && typeof y === 'number') {
        return Number.isNaN(x) && Number.isNaN(y);
      }
      return false;
    }

    // Cycle detection.
    let pairs = seen.get(x);
    if (pairs) {
      if (pairs.has(y)) return true; // same pair being compared = cycle match
    } else {
      pairs = new Set();
      seen.set(x, pairs);
    }
    pairs.add(y);

    const tagX = getTag(x);
    const tagY = getTag(y);
    if (tagX !== tagY) return false;

    // In strict mode, prototypes must match. This distinguishes a plain
    // object literal from a class instance with the same own properties.
    if (strict) {
      if (Object.getPrototypeOf(x) !== Object.getPrototypeOf(y)) return false;
    }

    switch (tagX) {
      case '[object Date]':
        return x.getTime() === y.getTime();
      case '[object RegExp]':
        return x.source === y.source && x.flags === y.flags;
      case '[object ArrayBuffer]': {
        if (x.byteLength !== y.byteLength) return false;
        const xa = new Uint8Array(x);
        const ya = new Uint8Array(y);
        for (let i = 0; i < xa.length; i++) if (xa[i] !== ya[i]) return false;
        return true;
      }
      case '[object Error]':
        return x.name === y.name && x.message === y.message;
    }

    if (isTypedArray(x) && isTypedArray(y)) {
      if (x.constructor !== y.constructor) return false;
      if (x.length !== y.length) return false;
      for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
      return true;
    }

    if (x instanceof Map && y instanceof Map) {
      if (x.size !== y.size) return false;
      // Order-insensitive: for each entry in x find a matching entry in y.
      const usedY = new Set();
      outer: for (const [kx, vx] of x) {
        let idx = 0;
        for (const [ky, vy] of y) {
          if (!usedY.has(idx) && eq(kx, ky) && eq(vx, vy)) {
            usedY.add(idx);
            continue outer;
          }
          idx++;
        }
        return false;
      }
      return true;
    }

    if (x instanceof Set && y instanceof Set) {
      if (x.size !== y.size) return false;
      const yArr = Array.from(y);
      const used = new Set();
      outer: for (const vx of x) {
        for (let i = 0; i < yArr.length; i++) {
          if (!used.has(i) && eq(vx, yArr[i])) {
            used.add(i);
            continue outer;
          }
        }
        return false;
      }
      return true;
    }

    if (Array.isArray(x) && Array.isArray(y)) {
      if (x.length !== y.length) return false;
      for (let i = 0; i < x.length; i++) {
        if (!eq(x[i], y[i])) return false;
      }
      return true;
    }

    // Plain objects (and class instances in non-strict mode).
    const keysX = Object.keys(x);
    const keysY = Object.keys(y);
    if (keysX.length !== keysY.length) return false;
    for (const k of keysX) {
      if (!Object.prototype.hasOwnProperty.call(y, k)) return false;
      if (!eq(x[k], y[k])) return false;
    }
    return true;
  }

  return eq(a, b);
}

// ---------------------------------------------------------------------------
// FNV-1a 64-bit (documented stand-in for Wyhash).
// ---------------------------------------------------------------------------

const FNV_OFFSET = 14695981039346656037n;
const FNV_PRIME = 1099511628211n;
const MASK64 = (1n << 64n) - 1n;
const encoder = new TextEncoder();

function fnv1a64(input) {
  let bytes;
  if (typeof input === 'string') {
    bytes = encoder.encode(input);
  } else if (input instanceof Uint8Array) {
    bytes = input;
  } else if (input instanceof ArrayBuffer) {
    bytes = new Uint8Array(input);
  } else if (ArrayBuffer.isView(input)) {
    bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  } else {
    bytes = encoder.encode(String(input));
  }
  let hash = FNV_OFFSET;
  for (let i = 0; i < bytes.length; i++) {
    hash ^= BigInt(bytes[i]);
    hash = (hash * FNV_PRIME) & MASK64;
  }
  return hash;
}

// ---------------------------------------------------------------------------
// randomUUIDv7 (RFC 9562) with an injectable clock.
// ---------------------------------------------------------------------------

function randomBytesHex(len) {
  const buf = Buffer.alloc(len);
  for (let i = 0; i < len; i++) buf[i] = Math.floor(Math.random() * 256);
  return buf;
}

function createUUIDv7(clock) {
  return function randomUUIDv7() {
    const ms = BigInt(clock());
    // 16 bytes total:
    //   bytes 0..5  : 48-bit big-endian unix millisecond timestamp
    //   bytes 6..7  : rand_a with version (0111) in the high nibble of byte 6
    //   bytes 8..15 : rand_b with variant (10)  in the high bits of byte 8
    const bytes = randomBytesHex(16);
    // Write 48-bit timestamp big-endian into bytes 0..5.
    const tsHex = ms.toString(16).padStart(12, '0').slice(-12);
    for (let i = 0; i < 6; i++) {
      bytes[i] = parseInt(tsHex.substr(i * 2, 2), 16);
    }
    // Version 7 -> 0111 in high nibble of byte 6.
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    // Variant 1 -> 10 in high bits of byte 8.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = bytes.toString('hex');
    return (
      hex.slice(0, 8) + '-' +
      hex.slice(8, 12) + '-' +
      hex.slice(12, 16) + '-' +
      hex.slice(16, 20) + '-' +
      hex.slice(20, 32)
    );
  };
}

// ---------------------------------------------------------------------------
// Sleep
// ---------------------------------------------------------------------------

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function sleepSync(ms) {
  // Atomics.wait on a SharedArrayBuffer. If SharedArrayBuffer is not
  // available (rare), fall back to a busy spin loop.
  const dur = Math.max(0, Number(ms) | 0);
  if (dur === 0) return;
  if (typeof SharedArrayBuffer !== 'undefined') {
    const sab = new SharedArrayBuffer(4);
    const i32 = new Int32Array(sab);
    Atomics.wait(i32, 0, 0, dur);
  } else {
    // Fallback: blocking via a child_process execFileSync of `sleep`
    // would violate the zero-dependency / no-spawn-in-lib policy; spin.
    const start = Date.now();
    while (Date.now() - start < dur) { /* spin */ }
  }
}

// ---------------------------------------------------------------------------
// assemble
// ---------------------------------------------------------------------------

function createUtil(options) {
  const opts = options || {};
  const env = opts.env || process.env;
  const version = opts.version || '1.1.0-tether';
  const clock = typeof opts.clock === 'function' ? opts.clock : Date.now;

  return {
    sleep,
    sleepSync,
    env,
    version,
    revision: 'tether-bun-compat+00000000',
    stringWidth,
    deepEquals,
    hash: fnv1a64,
    randomUUIDv7: createUUIDv7(clock),
    fileURLToPath: url.fileURLToPath,
    pathToFileURL: url.pathToFileURL,
    gc() { return 0; },
    main: process.argv[1] || '',
    nanoseconds: function nanoseconds() {
      // Bun.nanoseconds() returns a Number. process.hrtime.bigint is
      // BigInt; convert with loss of sub-nanosecond precision (fine).
      return Number(process.hrtime.bigint());
    },
    // Cached platform info for callers that expect Bun-shaped values.
    platform: opts.platformInfo ? opts.platformInfo : {
      platform: process.platform,
      arch: process.arch,
    },
  };
}

module.exports = {
  createUtil,
  stringWidth,
  deepEquals,
  fnv1a64,
  createUUIDv7,
  sleep,
  sleepSync,
};
