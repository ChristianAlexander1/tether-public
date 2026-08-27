'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { installBunGlobal } = require('../lib/index');

test.beforeEach(() => {
  delete globalThis.Bun;
});

test.after(() => {
  delete globalThis.Bun;
});

test('installBunGlobal returns the installed Bun object', () => {
  const bun = installBunGlobal();
  assert.ok(bun);
  assert.strictEqual(globalThis.Bun, bun);
  assert.equal(typeof bun.which, 'function');
  assert.equal(typeof bun.file, 'function');
  assert.equal(typeof bun.write, 'function');
  assert.equal(typeof bun.spawn, 'function');
  assert.equal(typeof bun.spawnSync, 'function');
  assert.equal(typeof bun.sleep, 'function');
  assert.equal(typeof bun.stringWidth, 'function');
  assert.equal(typeof bun.deepEquals, 'function');
  assert.equal(typeof bun.hash, 'function');
  assert.equal(typeof bun.randomUUIDv7, 'function');
});

test('default version is reported', () => {
  const bun = installBunGlobal();
  assert.strictEqual(bun.version, '1.1.0-tether');
  assert.strictEqual(typeof bun.revision, 'string');
  assert.ok(bun.revision.length > 0);
});

test('custom version is honored', () => {
  const bun = installBunGlobal({ version: '9.9.9-custom' });
  assert.strictEqual(bun.version, '9.9.9-custom');
});

test('calling twice without force throws EEXIST', () => {
  installBunGlobal();
  assert.throws(
    () => installBunGlobal(),
    (err) => err.code === 'EEXIST'
  );
});

test('calling twice with force:true replaces cleanly', () => {
  const first = installBunGlobal({ version: 'v1' });
  const second = installBunGlobal({ force: true, version: 'v2' });
  assert.notStrictEqual(first, second);
  assert.strictEqual(globalThis.Bun, second);
  assert.strictEqual(second.version, 'v2');
});

test('env injection captures same reference', () => {
  const env = { FOO: 'bar' };
  const bun = installBunGlobal({ env });
  assert.strictEqual(bun.env, env);
  assert.strictEqual(bun.env.FOO, 'bar');
});

test('platform info is honored when provided', () => {
  const bun = installBunGlobal({
    platformInfo: { platform: 'win32', arch: 'x64' },
  });
  assert.deepEqual(bun.platform, { platform: 'win32', arch: 'x64' });
});

test('Bun.main reflects process.argv[1] or empty string', () => {
  const bun = installBunGlobal();
  assert.strictEqual(bun.main, process.argv[1] || '');
});

test('gc is a no-op returning 0', () => {
  const bun = installBunGlobal();
  assert.strictEqual(bun.gc(), 0);
});

test('fileURLToPath / pathToFileURL delegate to node:url', () => {
  const bun = installBunGlobal();
  const u = bun.pathToFileURL('/tmp/foo.txt');
  assert.ok(u.href.startsWith('file:///'));
  assert.strictEqual(bun.fileURLToPath(u), '/tmp/foo.txt');
});
