'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createSpawnApi } = require('../lib/spawn');
const { makeFakeSpawn } = require('./fake-spawn');

test('spawn happy path: pid, streamed stdout, exited resolves, onExit fires once', async () => {
  const cp = makeFakeSpawn({
    scripts: { echo: { stdout: Buffer.from('hi\n'), exitCode: 0 } },
  });
  const { spawn } = createSpawnApi(cp);

  let onExitCalls = 0;
  let onExitArgs = null;
  const sub = spawn(['echo', 'hello'], {
    stdout: 'pipe',
    onExit: (s, code, signal, err) => {
      onExitCalls++;
      onExitArgs = { s, code, signal, err };
    },
  });

  assert.equal(typeof sub.pid, 'number');
  assert.ok(sub.stdout, 'stdout should be a ReadableStream');
  assert.ok(sub.stdout instanceof ReadableStream);

  const reader = sub.stdout.getReader();
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  const out = Buffer.concat(chunks.map(c => Buffer.from(c)));
  assert.equal(out.toString('utf8'), 'hi\n');

  const code = await sub.exited;
  assert.equal(code, 0);
  assert.equal(sub.exitCode, 0);
  // Allow the nextTick onExit to flush.
  await new Promise(r => setImmediate(r));
  assert.equal(onExitCalls, 1);
  assert.equal(onExitArgs.code, 0);
  assert.equal(onExitArgs.signal, null);
  assert.equal(onExitArgs.err, null);
});

test('spawn ENOENT throws synchronously with code ENOENT and no unhandled rejection/error', () => {
  const cp = makeFakeSpawn({
    throws: { 'missing-tool': { code: 'ENOENT' } },
  });
  const { spawn } = createSpawnApi(cp);

  let unhandled = null;
  function onUnhandledRejection(reason) { unhandled = reason; }
  function onUncaught(err) { unhandled = err; }
  process.on('unhandledRejection', onUnhandledRejection);
  process.on('uncaughtException', onUncaught);

  let caught;
  try {
    spawn(['missing-tool'], { stdout: 'pipe' });
  } catch (e) {
    caught = e;
  }

  assert.ok(caught, 'expected synchronous throw');
  assert.equal(caught.code, 'ENOENT');

  // Let any microtasks/timers flush and confirm nothing bubbled.
  return new Promise((resolve) => {
    setTimeout(() => {
      process.off('unhandledRejection', onUnhandledRejection);
      process.off('uncaughtException', onUncaught);
      assert.equal(unhandled, null, 'no unhandled rejection/error should occur');
      resolve();
    }, 50);
  });
});

test('spawn signal exit: SIGKILL -> exited 137, signalCode set, exitCode null', async () => {
  const cp = makeFakeSpawn({
    scripts: { runner: { signal: 'SIGKILL' } },
  });
  const { spawn } = createSpawnApi(cp);
  const sub = spawn(['runner'], { stdout: 'ignore', stderr: 'ignore' });
  const code = await sub.exited;
  assert.equal(code, 137);
  assert.equal(sub.signalCode, 'SIGKILL');
  assert.equal(sub.exitCode, null);
});

test('spawn kill() sends a signal and resolves exited', async () => {
  // The fake honors kill() by emitting close with the given signal.
  const cp = makeFakeSpawn({ scripts: { runner: {} } });
  const { spawn } = createSpawnApi(cp);
  const sub = spawn(['runner'], { stdout: 'ignore' });
  sub.kill('SIGKILL');
  const code = await sub.exited;
  assert.equal(code, 137);
  assert.equal(sub.signalCode, 'SIGKILL');
});

test('spawn supports stdin/stdout "inherit" and "ignore" passthrough', () => {
  const cp = makeFakeSpawn({ scripts: { x: { stdout: Buffer.from('') } } });
  const { spawn } = createSpawnApi(cp);
  const sub = spawn(['x'], { stdin: 'inherit', stdout: 'ignore', stderr: 'inherit' });
  assert.equal(sub.stdout, null);
  assert.equal(sub.stderr, null);
  // stdin for inherit is also null (no pipe).
  assert.equal(sub.stdin, null);
});

test('spawn unref()/ref() are chainable no-ops', () => {
  const cp = makeFakeSpawn({ scripts: { x: {} } });
  const { spawn } = createSpawnApi(cp);
  const sub = spawn(['x'], { stdout: 'ignore' });
  assert.equal(sub.unref(), sub);
  assert.equal(sub.ref(), sub);
});

test('spawnSync returns buffers and success=true on zero exit', () => {
  const cp = makeFakeSpawn({
    scripts: { echo: { stdout: Buffer.from('hello sync'), exitCode: 0 } },
  });
  const { spawnSync } = createSpawnApi(cp);
  const r = spawnSync(['echo', 'x'], { stdout: 'pipe' });
  assert.equal(r.success, true);
  assert.equal(r.exitCode, 0);
  assert.equal(r.signalCode, null);
  assert.ok(Buffer.isBuffer(r.stdout));
  assert.equal(r.stdout.toString('utf8'), 'hello sync');
});

test('spawnSync with non-zero exit: success false, exitCode correct, stdout intact', () => {
  const cp = makeFakeSpawn({
    scripts: { fail: { stdout: Buffer.from('partial'), exitCode: 2, stderr: Buffer.from('err') } },
  });
  const { spawnSync } = createSpawnApi(cp);
  const r = spawnSync(['fail'], { stdout: 'pipe', stderr: 'pipe' });
  assert.equal(r.success, false);
  assert.equal(r.exitCode, 2);
  assert.equal(r.stdout.toString('utf8'), 'partial');
  assert.equal(r.stderr.toString('utf8'), 'err');
});

test('spawnSync with signal: success false, signalCode set, exitCode null', () => {
  const cp = makeFakeSpawn({ scripts: { killed: { signal: 'SIGTERM' } } });
  const { spawnSync } = createSpawnApi(cp);
  const r = spawnSync(['killed'], {});
  assert.equal(r.success, false);
  assert.equal(r.exitCode, null);
  assert.equal(r.signalCode, 'SIGTERM');
});

test('spawn rejects empty argv with a synchronous error', () => {
  const cp = makeFakeSpawn({});
  const { spawn } = createSpawnApi(cp);
  assert.throws(() => spawn([]), /requires at least one argument/);
});
