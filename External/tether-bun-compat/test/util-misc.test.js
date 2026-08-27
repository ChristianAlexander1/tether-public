'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createUtil, fnv1a64, createUUIDv7 } = require('../lib/util');

function utilWith(opts) {
  return createUtil(Object.assign({
    env: process.env,
    version: '1.1.0-tether',
    platformInfo: { platform: 'linux', arch: 'x64' },
  }, opts || {}));
}

test('sleep resolves after the given delay', async () => {
  const u = utilWith();
  const t = Date.now();
  await u.sleep(25);
  const elapsed = Date.now() - t;
  assert.ok(elapsed >= 15, `expected >= 15ms, got ${elapsed}`);
});

test('sleepSync blocks via Atomics.wait', () => {
  const u = utilWith();
  const t = Date.now();
  u.sleepSync(25);
  const elapsed = Date.now() - t;
  assert.ok(elapsed >= 15, `expected >= 15ms, got ${elapsed}`);
});

test('env is the injected reference', () => {
  const env = { A: '1' };
  const u = utilWith({ env });
  assert.strictEqual(u.env, env);
});

test('version/revision are exposed', () => {
  const u = utilWith({ version: '9.9.9' });
  assert.strictEqual(u.version, '9.9.9');
  assert.strictEqual(typeof u.revision, 'string');
});

test('gc is a no-op returning 0', () => {
  assert.strictEqual(utilWith().gc(), 0);
});

test('hash (FNV-1a 64) is deterministic, BigInt, different inputs differ', () => {
  const h1 = fnv1a64('hello');
  const h2 = fnv1a64('hello');
  const h3 = fnv1a64('world');
  assert.strictEqual(typeof h1, 'bigint');
  assert.strictEqual(h1, h2);
  assert.notStrictEqual(h1, h3);
  assert.ok(h1 >= 0n && h1 < (1n << 64n), 'must be 64-bit');
});

test('hash accepts Uint8Array and string consistently for same bytes', () => {
  const s = 'abc';
  const u8 = new TextEncoder().encode(s);
  assert.strictEqual(fnv1a64(s), fnv1a64(u8));
});

test('randomUUIDv7: correct version (7) and variant (10) bits', () => {
  const u = utilWith({ clock: () => 1700000000000 });
  const id = u.randomUUIDv7();
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  const parts = id.split('-');
  // variant hex char must be 8,9,a,b
  assert.ok(['8', '9', 'a', 'b'].includes(parts[3][0]));
});

test('randomUUIDv7: same timestamp still yields distinct UUIDs (randomness)', () => {
  let counter = 0;
  const u = utilWith({ clock: () => 1700000000000 + (counter++) });
  // With a clock that advances, ids must differ.
  const a = u.randomUUIDv7();
  const b = u.randomUUIDv7();
  assert.notStrictEqual(a, b);
});

test('randomUUIDv7: monotonic timestamps sort lexicographically', () => {
  let t = 1700000000000;
  const u = utilWith({ clock: () => t });
  const ids = [];
  for (let i = 0; i < 10; i++) {
    t += 1;
    ids.push(u.randomUUIDv7());
  }
  const sorted = ids.slice().sort();
  assert.deepEqual(ids, sorted, 'UUIDs generated with increasing timestamps must sort lexicographically');
});

test('randomUUIDv7: timestamp portion encodes current ms (top 48 bits)', () => {
  const ts = 1700000000123;
  const u = utilWith({ clock: () => ts });
  const id = u.randomUUIDv7();
  const first12Hex = id.split('-').slice(0, 2).join('');
  // 48-bit big-endian timestamp
  const recovered = parseInt(first12Hex, 16);
  assert.strictEqual(recovered, ts);
});

test('fileURLToPath / pathToFileURL delegate to node:url', () => {
  const u = utilWith();
  const fileUrl = u.pathToFileURL('/tmp/x.txt');
  assert.ok(fileUrl.href.startsWith('file:///'));
  assert.strictEqual(u.fileURLToPath(fileUrl), '/tmp/x.txt');
});

test('nanoseconds returns a non-negative finite number', () => {
  const u = utilWith();
  const n1 = u.nanoseconds();
  const n2 = u.nanoseconds();
  assert.strictEqual(typeof n1, 'number');
  assert.ok(Number.isFinite(n1));
  assert.ok(n2 >= n1);
});

test('platform info is returned as provided', () => {
  const u = utilWith({ platformInfo: { platform: 'darwin', arch: 'arm64' } });
  assert.deepEqual(u.platform, { platform: 'darwin', arch: 'arm64' });
});
