'use strict';

const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const cp = require('../lib/child_process');
const ipc = require('../lib/ipc');
const mock = require('./mock-backend');

beforeEach(() => {
  mock.clear();
  ipc.setTransport(mock.createInProcessTransport());
});
afterEach(() => {
  ipc.clearTransport();
});

test('spawn collects stdout and emits spawn -> exit -> close in order', async () => {
  mock.register('prog', { stdout: 'hello world\n', exitCode: 0 });

  const child = cp.spawn('prog');
  const events = [];
  const chunks = [];
  child.stdout.on('data', (d) => {
    events.push('data:' + d.toString());
    chunks.push(d.toString());
  });
  child.on('spawn', () => events.push('spawn'));
  child.on('exit', () => events.push('exit'));
  child.on('close', () => events.push('close'));

  await new Promise((resolve) => child.on('close', () => setImmediate(resolve)));
  // Give any stream 'data' delivery (which is scheduled on a tick) a chance.
  await new Promise((resolve) => setImmediate(resolve));

  const code = child.exitCode;
  const sig = child.signalCode;
  assert.equal(code, 0);
  assert.equal(sig, null);
  assert.equal(chunks.join(''), 'hello world\n', 'stdout captured');

  const iSpawn = events.indexOf('spawn');
  const iExit = events.indexOf('exit');
  const iClose = events.indexOf('close');
  assert.equal(iSpawn, 0, 'spawn must be the first event');
  assert.ok(iSpawn < iExit, 'spawn must precede exit');
  assert.ok(iExit < iClose, 'exit must precede close');
});

test('spawn of a missing command emits error with the ENOENT shape', async () => {
  const child = cp.spawn('definitely-not-a-command');
  const err = await new Promise((resolve, reject) => {
    child.on('error', resolve);
    child.on('exit', () => reject(new Error('should not emit exit for a failed spawn')));
  });

  assert.equal(err.code, 'ENOENT');
  assert.equal(err.errno, -2);
  assert.equal(err.syscall, 'spawn definitely-not-a-command');
  assert.equal(err.path, 'definitely-not-a-command');
  assert.equal(child.pid, undefined);
  assert.equal(child.exitCode, null);
  assert.equal(child.signalCode, null);
});

test('spawn honors custom cwd/env in the request payload', async () => {
  mock.register('prog', { stdout: '', exitCode: 0 });
  cp.spawn('prog', ['--flag'], { cwd: '/work', env: { A: '1' } });
  await new Promise((resolve) => setTimeout(resolve, 10));
  const req = mock.requests[0];
  assert.equal(req.cwd, '/work');
  assert.deepEqual(req.env, { A: '1' });
  assert.deepEqual(req.args, ['--flag']);
});

test('spawn kill() on an already-exited child returns false and does not throw', async () => {
  // The protocol is synchronous request/reply, so by the time the caller gets a
  // handle back the command has already run to completion. killing a finished
  // child must return false (matching Node) rather than throw.
  mock.register('quick', { stdout: '', exitCode: 0 });
  const child = cp.spawn('quick');
  await new Promise((resolve) => child.on('close', resolve));
  assert.equal(child.kill('SIGTERM'), false);
});

test('signal op is delivered to the engine and acknowledged', () => {
  const reply = ipc.roundTrip({ op: 'signal', pid: 1, signal: 'SIGTERM' });
  assert.deepEqual(reply, { ok: true });
});

test('spawnSync with input, encoding=string', () => {
  mock.register('cat', { stdoutFromInput: true });
  const r = cp.spawnSync('cat', { input: 'abc\ndef\n', encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.equal(r.signal, null);
  assert.equal(r.error, null);
  assert.equal(r.stdout, 'abc\ndef\n');
  assert.ok(typeof r.stdout === 'string');
  assert.equal(r.stderr, '');
  assert.equal(r.output[1], 'abc\ndef\n');
  assert.equal(r.output[0], null);
});

test('spawnSync with input, encoding=buffer returns Buffers', () => {
  mock.register('cat', { stdoutFromInput: true });
  const r = cp.spawnSync('cat', { input: 'bytes', encoding: 'buffer' });
  assert.ok(Buffer.isBuffer(r.stdout));
  assert.equal(r.stdout.toString('utf8'), 'bytes');
  assert.ok(Buffer.isBuffer(r.stderr));
  assert.ok(Buffer.isBuffer(r.output[1]));
});

test('spawnSync default encoding (no encoding key) returns Buffers', () => {
  mock.register('cat', { stdout: 'raw\n' });
  const r = cp.spawnSync('cat');
  assert.ok(Buffer.isBuffer(r.stdout));
  assert.equal(r.stdout.toString('utf8'), 'raw\n');
});

test('spawnSync reports pid and output array', () => {
  mock.register('prog', { stdout: 'a', stderr: 'b', exitCode: 0 });
  const r = cp.spawnSync('prog');
  assert.equal(typeof r.pid, 'number');
  assert.deepEqual(r.output, [null, Buffer.from('a'), Buffer.from('b')]);
});

test('spawnSync of a missing command returns error result (no throw)', () => {
  const r = cp.spawnSync('nope');
  assert.ok(r.error instanceof Error);
  assert.equal(r.error.code, 'ENOENT');
  assert.equal(r.status, null);
  assert.equal(r.signal, null);
  assert.equal(r.stdout, null);
  assert.equal(r.stderr, null);
});

test('exec callback on success', async () => {
  mock.register('/bin/sh', { stdout: 'ran ok\n', exitCode: 0 });
  const [err, stdout, stderr] = await new Promise((resolve) => {
    cp.exec('anything', (e, so, se) => resolve([e, so, se]));
  });
  assert.equal(err, null);
  assert.equal(stdout, 'ran ok\n');
  assert.equal(typeof stderr, 'string');
});

test('exec callback on non-zero exit sets error.code to the exit status', async () => {
  mock.register('/bin/sh', { stderr: 'boom', exitCode: 3 });
  const [err, stdout, stderr] = await new Promise((resolve) => {
    cp.exec('x', (e, so, se) => resolve([e, so, se]));
  });
  assert.ok(err instanceof Error);
  assert.equal(err.code, 3);
  assert.equal(err.killed, false);
  assert.equal(stderr, 'boom');
  assert.equal(stdout, '');
});

test('execFile runs the file directly (no shell) and passes args', async () => {
  mock.register('myprog', { stdout: 'direct\n', exitCode: 0 });
  const [err, stdout] = await new Promise((resolve) => {
    cp.execFile('myprog', ['a', 'b'], (e, so) => resolve([e, so]));
  });
  assert.equal(err, null);
  assert.equal(stdout, 'direct\n');
  const req = mock.requests[0];
  assert.equal(req.op, 'spawnSync');
  assert.equal(req.file, 'myprog');
  assert.deepEqual(req.args, ['a', 'b']);
  assert.equal(req.shell, false);
});

test('execSync throws with status/stdout/stderr populated on non-zero exit', () => {
  mock.register('/bin/sh', { stdout: 'out-line\n', stderr: 'err-line\n', exitCode: 2 });
  let threw = null;
  try {
    cp.execSync('somefailingcmd');
  } catch (e) {
    threw = e;
  }
  assert.ok(threw, 'expected execSync to throw');
  assert.equal(threw.status, 2);
  assert.equal(threw.code, 2);
  assert.equal(threw.stdout, 'out-line\n');
  assert.equal(threw.stderr, 'err-line\n');
  assert.ok(threw.message.includes('somefailingcmd'), 'message should contain the command');
});

test('execFileSync returns stdout on success', () => {
  mock.register('myprog', { stdout: 'ok!\n', exitCode: 0 });
  assert.equal(cp.execFileSync('myprog'), 'ok!\n');
});

test('maxBuffer overflow produces ERR_CHILD_PROCESS_STDIO_MAXBUFFER', () => {
  mock.register('big', { stdout: 'x'.repeat(1000), exitCode: 0 });
  let err = null;
  try {
    cp.execFileSync('big', { maxBuffer: 100 });
  } catch (e) {
    err = e;
  }
  assert.ok(err);
  assert.equal(err.code, 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER');
});

test('maxBuffer overflow also surfaces through async execFile callback', async () => {
  mock.register('big', { stdout: 'x'.repeat(1000), exitCode: 0 });
  const err = await new Promise((resolve) => {
    cp.execFile('big', [], { maxBuffer: 100 }, (e) => resolve(e));
  });
  assert.ok(err);
  assert.equal(err.code, 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER');
});

test('timeout terminates a long command and reports the signal', () => {
  mock.register('slow', { stdout: '', stderr: '', exitCode: 0, delay: 60000 });
  const r = cp.spawnSync('slow', { timeout: 50, killSignal: 'SIGTERM' });
  assert.equal(r.status, null);
  assert.equal(r.signal, 'SIGTERM');
  assert.ok(r.error, 'expected a timeout error');
  assert.equal(r.error.code, 'ETIMEDOUT');
  assert.equal(r.error.signal, 'SIGTERM');
});

test('shell:true routes through sh -c (assert request payload)', () => {
  mock.register('/bin/sh', { stdout: 'ok', exitCode: 0 });
  const r = cp.spawnSync('echo', ['hi', 'there'], { shell: true });
  assert.equal(r.status, 0);
  const req = mock.requests[0];
  assert.equal(req.op, 'spawnSync');
  assert.equal(req.file, '/bin/sh');
  assert.equal(req.args[0], '-c');
  assert.equal(req.args[1], 'echo hi there');
  assert.equal(req.shell, true);
});

test('shell:true with an explicit shell path is honoured', () => {
  mock.register('/custom/sh', { stdout: 'x', exitCode: 0 });
  cp.spawnSync('cmd', { shell: '/custom/sh' });
  const req = mock.requests[0];
  assert.equal(req.file, '/custom/sh');
  assert.equal(req.args[0], '-c');
});

test('stdio "ignore" produces no captured output', () => {
  mock.register('prog', { stdout: 'hidden\n', stderr: 'eh\n', exitCode: 4 });
  const r = cp.spawnSync('prog', { stdio: 'ignore' });
  assert.equal(r.stdout, null);
  assert.equal(r.stderr, null);
  assert.deepEqual(r.output, [null, null, null]);
  assert.equal(r.status, 4);
});

test('stdio "inherit" passes output through and does not capture', () => {
  mock.register('prog', { stdout: 'v', stderr: 'w', exitCode: 0 });
  // Capture process writes by temporarily swapping.
  const oldOut = process.stdout.write;
  const oldErr = process.stderr.write;
  let outBuf = '';
  let errBuf = '';
  process.stdout.write = (s) => { outBuf += s; return true; };
  process.stderr.write = (s) => { errBuf += s; return true; };
  try {
    const r = cp.spawnSync('prog', { stdio: 'inherit' });
    assert.equal(r.stdout, null);
    assert.equal(r.stderr, null);
    assert.equal(outBuf, 'v');
    assert.equal(errBuf, 'w');
  } finally {
    process.stdout.write = oldOut;
    process.stderr.write = oldErr;
  }
});

test('spawn stdio array selects per-stream behaviour', async () => {
  mock.register('prog', { stdout: 'captured\n', stderr: 'ignored\n', exitCode: 0 });
  const child = cp.spawn('prog', { stdio: ['ignore', 'pipe', 'ignore'] });
  const data = await new Promise((resolve) => {
    let s = '';
    child.stdout.on('data', (d) => (s += d.toString()));
    child.on('close', () => setImmediate(() => resolve(s)));
  });
  assert.equal(data, 'captured\n');
  assert.equal(child.stderr, null);
  assert.equal(child.stdin, null);
});

test('spawn stdio "inherit" sets the child streams to process streams', async () => {
  mock.register('prog', { stdout: '', exitCode: 0 });
  const child = cp.spawn('prog', { stdio: 'inherit' });
  assert.equal(child.stdout, process.stdout);
  assert.equal(child.stderr, process.stderr);
  assert.equal(child.stdin, process.stdin);
  await new Promise((resolve) => child.on('close', resolve));
});

test('normalised call forms: spawn(file), spawn(file, opts), spawn(file, args, opts)', async () => {
  mock.register('prog', { stdout: '', exitCode: 0 });
  cp.spawn('prog');
  await new Promise((r) => setTimeout(r, 5));
  cp.spawn('prog', { cwd: '/x' });
  await new Promise((r) => setTimeout(r, 5));
  cp.spawn('prog', ['--z'], { cwd: '/y' });
  await new Promise((r) => setTimeout(r, 5));
  assert.deepEqual(mock.requests.map((r) => r.args), [[], [], ['--z']]);
  assert.deepEqual(mock.requests.map((r) => r.cwd), [process.cwd(), '/x', '/y']);
});

test('fork returns a ChildProcess with the IPC surface', async () => {
  // fork() spawns the configured node executable; register it so the deferred
  // spawn dispatch succeeds, then await it so nothing leaks.
  mock.register(process.execPath, { stdout: '', exitCode: 0 });
  const child = cp.fork('./worker.js', ['a'], { stdio: 'ignore' });
  assert.ok(child.pid === undefined); // pid only known after dispatch
  assert.equal(typeof child.send, 'function');
  assert.equal(typeof child.disconnect, 'function');
  assert.equal(child.send({ x: 1 }), false);
  child.disconnect(); // should not throw
  const outcome = await new Promise((resolve) => {
    child.on('error', (e) => resolve({ error: e }));
    child.on('close', () => resolve({ closed: true }));
  });
  assert.deepEqual(outcome, { closed: true });
  assert.equal(child.exitCode, 0);
});

test('unrecognised op replies with an unknown-op error', () => {
  const reply = mock.handleRequest({ op: 'bogus' });
  assert.equal(reply.error, 'unknown op bogus');
});

test('encoding "buffer" and explicit utf8 both decode correctly', () => {
  mock.register('cat', { stdout: 'caf\u00e9\n' });
  const a = cp.spawnSync('cat', { encoding: 'utf8' });
  assert.equal(a.stdout, 'caf\u00e9\n');
  const b = cp.spawnSync('cat', { encoding: 'buffer' });
  assert.ok(Buffer.isBuffer(b.stdout));
  assert.equal(b.stdout.toString('utf8'), 'caf\u00e9\n');
});
