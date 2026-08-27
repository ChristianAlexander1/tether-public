'use strict';

// test/smoke-default-wiring.test.js — the only test permitted to spawn
// `node` itself (per the brief). Exercises installBunGlobal() with no
// injections and confirms Bun.which finds `node`, Bun.spawn runs it,
// and Bun.sleep/stringWidth work against the real runtime.

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { installBunGlobal } = require('../lib/index');

before(() => {
  delete globalThis.Bun;
  installBunGlobal({ force: true });
});

after(() => {
  delete globalThis.Bun;
});

test('default wiring: Bun.version is set and Bun is global', () => {
  assert.ok(globalThis.Bun);
  assert.strictEqual(typeof Bun.version, 'string');
});

test('default wiring: Bun.which finds "node" via real PATH scan', () => {
  const found = Bun.which('node');
  assert.ok(found, 'expected Bun.which("node") to find node in PATH');
  assert.ok(typeof found === 'string');
});

test('default wiring: Bun.which returns null for nonsense', () => {
  assert.strictEqual(Bun.which('this-binary-definitely-does-not-exist-xyz'), null);
});

test('default wiring: Bun.spawn runs `node -e process.stdout.write("ok")`', async () => {
  const sub = Bun.spawn(
    [process.execPath, '-e', 'process.stdout.write("ok")'],
    { stdout: 'pipe' }
  );
  const reader = sub.stdout.getReader();
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  const out = Buffer.concat(chunks.map(c => Buffer.from(c)));
  assert.equal(out.toString('utf8'), 'ok');
  const code = await sub.exited;
  assert.equal(code, 0);
});

test('default wiring: Bun.spawnSync returns buffer output and success', () => {
  const r = Bun.spawnSync(
    [process.execPath, '-e', 'process.stdout.write("sync-ok")'],
    { stdout: 'pipe' }
  );
  assert.equal(r.success, true);
  assert.equal(r.exitCode, 0);
  assert.equal(r.stdout.toString('utf8'), 'sync-ok');
});

test('default wiring: Bun.sleep and stringWidth against the real runtime', async () => {
  const t = Date.now();
  await Bun.sleep(10);
  assert.ok(Date.now() - t >= 5);
  assert.equal(Bun.stringWidth('hello'), 5);
});
