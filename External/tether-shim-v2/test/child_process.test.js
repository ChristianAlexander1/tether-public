'use strict';

// child_process over the spawn domain: synchronous return + async pid,
// 'spawn' event, ordered exit/close, stdin over the wire, kill() semantics,
// pty flag, exec/execFile buffering, and the spawnSync second connection.

const test = require('node:test');
const assert = require('node:assert/strict');

const { setup, nextEvent, settle, until } = require('./helpers');
const cp = require('../lib/child_process');

const session = setup({
  ttyFds: [0, 1, 2],
  unresolvable: ['no-such-binary'],
});

/** Wait for the mock to register the process backing `child`. */
async function mockProc(server, child) {
  await until(() => server.processes.has(child.pid), { message: 'mock process registered' });
  return server.processes.get(child.pid);
}

test('cp: spawn returns a ChildProcess synchronously; pid arrives with the reply', async () => {
  await session;
  const child = cp.spawn('echo', ['hi']);
  assert.ok(child instanceof cp.ChildProcess);
  assert.equal(child.pid, undefined, 'pid is undefined until spawn.start replies');
  assert.ok(child.stdin, 'stdin exists synchronously');
  assert.ok(child.stdout, 'stdout exists synchronously');
  assert.ok(child.stderr, 'stderr exists synchronously');
  assert.deepEqual(child.stdio, [child.stdin, child.stdout, child.stderr]);

  const spawnEvt = nextEvent(child, 'spawn');
  await until(() => child.pid !== undefined, { message: 'pid set' });
  await spawnEvt;
  assert.ok(Number.isInteger(child.pid), 'pid is a real integer from the server');
  assert.equal(child.connected, true);
  child.stdout.resume();
  child.stderr.resume();
});

test('cp: ref and unref are chainable for detached desktop opener libraries', async () => {
  const child = cp.spawn('xdg-open', ['https://example.com'], {
    stdio: 'ignore',
    detached: true,
  });

  assert.equal(child.unref(), child);
  assert.equal(child.ref(), child);
  assert.equal(child.unref(), child);
  await until(() => child.pid !== undefined, { message: 'pid set' });
});

test('cp: spawn.start body carries argv/cwd/env/stdio per spec', async () => {
  const { server } = await session;
  const child = cp.spawn('grep', ['-r', 'x', '.'], { cwd: '/work', env: { A: 'b' } });
  await until(() => child.pid !== undefined, { message: 'pid set' });
  const req = server.requestsOfType('spawn.start').at(-1);
  assert.deepEqual(req.body.argv, ['grep', '-r', 'x', '.']);
  assert.equal(req.body.cwd, '/work');
  assert.deepEqual(req.body.env, { A: 'b' });
  assert.deepEqual(req.body.stdio, ['pipe', 'pipe', 'pipe'], 'stdio normalized to 3-entry string form');
  assert.equal(req.body.pty, false);
  child.stdout.resume();
  child.stderr.resume();
});

test('cp: stdio string form expands; short arrays pad with pipe', async () => {
  const { server } = await session;
  const a = cp.spawn('x-tool', [], { stdio: 'ignore' });
  await until(() => a.pid !== undefined, { message: 'pid set a' });
  assert.deepEqual(server.requestsOfType('spawn.start').at(-1).body.stdio, ['ignore', 'ignore', 'ignore']);
  const b = cp.spawn('x-tool', [], { stdio: ['pipe', 'ignore'] });
  await until(() => b.pid !== undefined, { message: 'pid set b' });
  assert.deepEqual(server.requestsOfType('spawn.start').at(-1).body.stdio, ['pipe', 'ignore', 'pipe']);
  a.stdout.resume();
  b.stdout.resume();
});

test('cp: stdout/stderr events decode base64 and reach the Readables in order', async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  const chunks = [];
  const errChunks = [];
  child.stdout.on('data', (d) => chunks.push(d));
  child.stderr.on('data', (d) => errChunks.push(d));
  const closed = nextEvent(child, 'close');
  await until(() => child.pid !== undefined, { message: 'pid set' });

  server.queueOutput(child.pid, 'stdout', Buffer.from('one'));
  server.queueOutput(child.pid, 'stdout', Buffer.from('two'));
  server.queueOutput(child.pid, 'stderr', Buffer.from('oops'));
  server.exitProcess(child.pid, 0, null);

  const [code, signal] = await closed;
  assert.equal(code, 0);
  assert.equal(signal, null);
  assert.equal(Buffer.concat(chunks).toString(), 'onetwo');
  assert.equal(Buffer.concat(errChunks).toString(), 'oops');
});

test("cp: event order is 'spawn' → 'exit' → readable 'end' → 'close'", async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  const order = [];
  child.on('spawn', () => order.push('spawn'));
  child.on('exit', (code, signal) => order.push(`exit:${code}:${signal}`));
  child.on('close', (code, signal) => order.push(`close:${code}:${signal}`));
  child.stdout.on('data', () => {});
  child.stderr.on('data', () => {});
  child.stdout.on('end', () => order.push('stdout-end'));
  child.stderr.on('end', () => order.push('stderr-end'));

  await until(() => child.pid !== undefined, { message: 'pid set' });
  server.exitProcess(child.pid, 7, null);
  await until(() => order.includes('close:7:null'), { message: 'close fired' });

  assert.equal(order[0], 'spawn', 'spawn first');
  assert.equal(order[1], 'exit:7:null', 'exit second');
  assert.ok(order.indexOf('stdout-end') > order.indexOf('exit:7:null'), 'stdout ends after exit');
  assert.ok(order.indexOf('stderr-end') > order.indexOf('exit:7:null'), 'stderr ends after exit');
  assert.equal(order.at(-1), 'close:7:null', 'close last');
  assert.equal(child.exitCode, 7);
  assert.equal(child.signalCode, null);
});

test('cp: exactly one spawn.exit per pid — duplicate exits are ignored', async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  const exits = [];
  child.on('exit', (c, s) => exits.push([c, s]));
  child.stdout.resume();
  child.stderr.resume();
  await until(() => child.pid !== undefined, { message: 'pid set' });

  server.exitProcess(child.pid, 3, null);
  server.push('spawn.exit', { pid: child.pid, code: 99, signal: null }); // stray duplicate
  await settle();
  assert.equal(exits.length, 1, 'only the first exit counts');
  assert.deepEqual(exits[0], [3, null]);
});

test("cp: spawn.start ENOENT → 'error' once, never 'exit'/'close' (edge 5)", async () => {
  await session;
  const child = cp.spawn('no-such-binary', ['--flag']);
  const errors = [];
  let sawExit = false;
  let sawClose = false;
  child.on('error', (err) => errors.push(err));
  child.on('exit', () => (sawExit = true));
  child.on('close', () => (sawClose = true));
  child.stdout.on('data', () => {});
  child.stderr.on('data', () => {});

  await until(() => errors.length === 1, { message: 'error emitted' });
  assert.equal(errors[0].code, 'ENOENT');
  assert.equal(errors[0].path, 'no-such-binary');
  assert.match(errors[0].syscall, /^spawn /);

  await settle(5);
  assert.equal(errors.length, 1, 'error emitted exactly once');
  assert.equal(sawExit, false, 'no exit event (matches real Node)');
  assert.equal(sawClose, false, 'no close event (matches real Node)');
  assert.equal(child.pid, undefined, 'pid never assigned');
});

test("cp: spawn.exit with signal → exit(null,'SIGKILL') then close(null,'SIGKILL') (edge 11)", async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  const order = [];
  child.on('exit', (code, signal) => order.push(['exit', code, signal]));
  child.on('close', (code, signal) => order.push(['close', code, signal]));
  child.stdout.on('data', () => {});
  child.stderr.on('data', () => {});

  await until(() => child.pid !== undefined, { message: 'pid set' });
  server.exitProcess(child.pid, null, 'SIGKILL');
  await until(() => order.length === 2, { message: 'exit+close fired' });

  assert.deepEqual(order[0], ['exit', null, 'SIGKILL'], 'code/signal are mutually exclusive');
  assert.deepEqual(order[1], ['close', null, 'SIGKILL']);
  assert.equal(child.signalCode, 'SIGKILL');
  assert.equal(child.exitCode, null);
});

test('cp: stdin writes reach the server in order; end() sends spawn.stdinEnd', async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  await until(() => child.pid !== undefined, { message: 'pid set' });
  const proc = await mockProc(server, child);

  const writesDone = [];
  child.stdin.write('hello ', () => writesDone.push(1));
  child.stdin.write('world', () => writesDone.push(2));
  const ended = nextEvent(server, 'stdinEnd');
  child.stdin.end(() => writesDone.push('end'));

  await ended;
  await until(() => writesDone.length === 3, { message: 'all write callbacks ran' });
  assert.deepEqual(writesDone, [1, 2, 'end'], 'callbacks fire in order');
  assert.equal(Buffer.concat(proc.stdin).toString(), 'hello world');
  assert.equal(proc.stdinEnded, true);
  child.stdout.resume();
  child.stderr.resume();
});

test('cp: stdin writes larger than 64 KiB are split into <= 64 KiB raw chunks', async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  await until(() => child.pid !== undefined, { message: 'pid set' });
  const proc = await mockProc(server, child);

  const payload = Buffer.alloc(65536 * 2 + 1234, 0x61);
  const ended = nextEvent(server, 'stdinEnd');
  child.stdin.end(payload);
  await ended;

  assert.equal(proc.stdin.length, 3, 'split into 64 KiB + 64 KiB + remainder');
  assert.equal(proc.stdin[0].length, 65536);
  assert.equal(proc.stdin[1].length, 65536);
  assert.equal(proc.stdin[2].length, 1234);
  assert.equal(Buffer.concat(proc.stdin).equals(payload), true);
  child.stdout.resume();
  child.stderr.resume();
});

test('cp: kill() sends spawn.kill, returns true; exit arrives with the signal', async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  await until(() => child.pid !== undefined, { message: 'pid set' });

  const exitArgs = nextEvent(child, 'exit');
  const returned = child.kill('SIGTERM');
  assert.equal(returned, true, 'true when the request was sent');
  assert.equal(child.killed, true);

  const req = server.requestsOfType('spawn.kill').at(-1);
  assert.deepEqual(req.body, { pid: child.pid, signal: 'SIGTERM' });

  const [code, signal] = await exitArgs;
  assert.equal(code, null);
  assert.equal(signal, 'SIGTERM');
  child.stdout.resume();
  child.stderr.resume();
});

test('cp: kill() after exit returns false; ESRCH replies are swallowed', async () => {
  const { server } = await session;
  const child = cp.spawn('x-tool');
  await until(() => child.pid !== undefined, { message: 'pid set' });
  const exited = nextEvent(child, 'exit');
  server.exitProcess(child.pid, 0, null);
  await exited;

  assert.equal(child.kill('SIGTERM'), false, 'dead child → false, nothing sent');
  const killCountBefore = server.requestsOfType('spawn.kill').length;
  await settle(3);
  assert.equal(server.requestsOfType('spawn.kill').length, killCountBefore, 'no request sent for a dead child');

  // Server-side death racing the client's view: the process is gone on the
  // server but the client has not seen spawn.exit, so kill() sends the
  // request and the ESRCH reply must be swallowed silently.
  const racer = cp.spawn('x-tool');
  await until(() => racer.pid !== undefined, { message: 'racer pid set' });
  racer.stdout.resume();
  racer.stderr.resume();
  const racerErrors = [];
  racer.on('error', (err) => racerErrors.push(err));
  server.processes.delete(racer.pid); // simulate the process dying server-side
  assert.equal(racer.kill('SIGTERM'), true, 'request sent while the client still sees it alive');
  await settle(5);
  const killReqs = server.requestsOfType('spawn.kill');
  assert.equal(killReqs.at(-1).body.pid, racer.pid, 'the racing kill reached the server');
  assert.equal(racerErrors.length, 0, 'ESRCH swallowed without surfacing an error');
  child.stdout.resume();
  child.stderr.resume();
});

test('cp: pty:true only when stdio==="inherit" and fd 0 is a genuine TTY', async () => {
  const { server } = await session;
  // ttyFds includes 0 in this session, so 'inherit' implies pty.
  const withPty = cp.spawn('x-tool', [], { stdio: 'inherit' });
  await until(() => withPty.pid !== undefined, { message: 'pty pid set' });
  assert.equal(server.requestsOfType('spawn.start').at(-1).body.pty, true);
  assert.deepEqual(server.requestsOfType('spawn.start').at(-1).body.stdio, ['inherit', 'inherit', 'inherit']);

  const noPty = cp.spawn('x-tool', [], { stdio: 'pipe' });
  await until(() => noPty.pid !== undefined, { message: 'pipe pid set' });
  assert.equal(server.requestsOfType('spawn.start').at(-1).body.pty, false);
});

test('cp: spawn.resize → EINVAL unless the child is a pty; ok when it is', async () => {
  const { server } = await session;
  const piped = cp.spawn('x-tool', [], { stdio: 'pipe' });
  await until(() => piped.pid !== undefined, { message: 'piped pid set' });
  const pipedRes = await piped.resize(100, 50);
  assert.equal(pipedRes.ok, false);
  assert.equal(pipedRes.code, 'EINVAL', 'resize on non-pty child → EINVAL');

  const ptyChild = cp.spawn('x-tool', [], { stdio: 'inherit' });
  await until(() => ptyChild.pid !== undefined, { message: 'pty pid set' });
  const ptyRes = await ptyChild.resize(132, 43);
  assert.equal(ptyRes.ok, true);
  const proc = server.processes.get(ptyChild.pid);
  assert.equal(proc.cols, 132);
  assert.equal(proc.rows, 43);
});

test('cp: exec uses the spec shell argv and the (error, stdout, stderr) contract', async () => {
  const { server } = await session;
  let observedArgv = null;
  server.once('spawn', (proc, body) => {
    observedArgv = body.argv;
    server.queueOutput(proc.pid, 'stdout', Buffer.from('exec-out'));
    server.queueOutput(proc.pid, 'stderr', Buffer.from('exec-err'));
    server.exitProcess(proc.pid, 0, null);
  });

  const result = await new Promise((resolve) => {
    cp.exec('ls -la', (error, stdout, stderr) => resolve({ error, stdout, stderr }));
  });
  assert.deepEqual(observedArgv, ['/bin/sh', '-c', 'ls -la'], 'shell argv per spec');
  assert.equal(result.error, null);
  assert.equal(result.stdout, 'exec-out');
  assert.equal(result.stderr, 'exec-err');
});

test('cp: exec surfaces nonzero exit codes as error.code (Node contract)', async () => {
  const { server } = await session;
  server.once('spawn', (proc) => {
    server.queueOutput(proc.pid, 'stderr', Buffer.from('bad input'));
    server.exitProcess(proc.pid, 2, null);
  });
  const result = await new Promise((resolve) => {
    cp.exec('fail-cmd', (error, stdout, stderr) => resolve({ error, stdout, stderr }));
  });
  assert.ok(result.error, 'error is set for nonzero exit');
  assert.equal(result.error.code, 2, 'numeric exit code in error.code');
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'bad input');
});

test('cp: execFile passes args without a shell', async () => {
  const { server } = await session;
  let observedArgv = null;
  server.once('spawn', (proc, body) => {
    observedArgv = body.argv;
    server.queueOutput(proc.pid, 'stdout', Buffer.from('converted'));
    server.exitProcess(proc.pid, 0, null);
  });
  const result = await new Promise((resolve) => {
    cp.execFile('convert', ['--in', 'a.png', 'b.png'], (error, stdout) => resolve({ error, stdout }));
  });
  assert.deepEqual(observedArgv, ['convert', '--in', 'a.png', 'b.png']);
  assert.equal(result.error, null);
  assert.equal(result.stdout, 'converted');
});

test('cp: maxBuffer overflow kills the child and errors with ENOBUFS', async () => {
  const { server } = await session;
  server.once('spawn', (proc) => {
    server.queueOutput(proc.pid, 'stdout', Buffer.alloc(2048, 0x78));
    // No exit yet: the overflow path must kill the child itself.
  });
  const result = await new Promise((resolve) => {
    cp.exec('big-out', { maxBuffer: 1024 }, (error, stdout) => resolve({ error, stdout }));
  });
  assert.ok(result.error, 'error reported on overflow');
  assert.equal(result.error.code, 'ENOBUFS');
  assert.match(result.error.message, /maxBuffer/);
  await until(
    () => server.requestsOfType('spawn.kill').length > 0,
    { message: 'child killed on overflow' }
  );
  assert.equal(server.requestsOfType('spawn.kill').at(-1).body.signal, 'SIGTERM');
});

// --------------------------------------------------------------- spawnSync

test('cp: spawnSync runs over a SECOND connection with role node-shim-sync', async () => {
  const { server } = await session;
  const hellosBefore = server.hellos.length;
  const connsBefore = server.connections.length;

  server.once('stdinEnd', (proc) => {
    server.queueOutput(proc.pid, 'stdout', Buffer.concat(proc.stdin)); // echo
    server.queueOutput(proc.pid, 'stderr', Buffer.from('sync-err'));
    server.exitProcess(proc.pid, 0, null);
  });

  const result = cp.spawnSync('cat-like', ['-'], { input: 'hello sync' });
  assert.equal(result.error, undefined, `no error: ${result.error && result.error.message}`);
  assert.equal(result.status, 0);
  assert.equal(result.signal, null);
  assert.equal(result.stdout, 'hello sync');
  assert.equal(result.stderr, 'sync-err');
  assert.ok(Number.isInteger(result.pid));
  assert.equal(result.output[1].toString(), 'hello sync');

  assert.equal(server.connections.length, connsBefore + 1, 'a second connection was opened');
  assert.equal(server.hellos.length, hellosBefore + 1, 'the second connection handshook');
  const syncHello = server.hellos.at(-1);
  assert.equal(syncHello.role, 'node-shim-sync', 'dedicated sync role per spec');
  assert.equal(syncHello.proto, 2);
  // The main connection's hello keeps the normal role.
  assert.equal(server.hellos[0].role, 'node-shim');
});

test('cp: spawnSync propagates exit codes and acks every byte it consumes', async () => {
  const { server } = await session;
  server.once('stdinEnd', (proc) => {
    server.queueOutput(proc.pid, 'stdout', Buffer.from('x'.repeat(1000)));
    server.exitProcess(proc.pid, 42, null);
  });
  const result = cp.spawnSync('exit-42', []);
  assert.equal(result.status, 42);
  assert.equal(result.signal, null);
  assert.equal(result.stdout.length, 1000);
  assert.equal(server.totalAcked(result.pid), 1000, 'sync path acks consumed bytes exactly');
});

test('cp: spawnSync ENOENT surfaces as result.error without throwing', async () => {
  await session;
  const result = cp.spawnSync('no-such-binary', []);
  assert.ok(result.error, 'error present');
  assert.equal(result.error.code, 'ENOENT');
  assert.equal(result.status, null);
  assert.equal(result.stdout, '');
});

test('cp: spawnSync honors the stdin window across multiple chunks', async () => {
  const { server } = await session;
  let firstWindowSet = false;
  server.on('spawn', (proc) => {
    if (!firstWindowSet) {
      firstWindowSet = true;
      proc.window = 1024; // small positive window reported by every response
    }
  });
  server.once('stdinEnd', (proc) => {
    server.queueOutput(proc.pid, 'stdout', Buffer.concat(proc.stdin));
    proc.window = 65536;
    server.exitProcess(proc.pid, 0, null);
  });
  // > 2 * 64 KiB so the sync loop issues several spawn.stdin requests.
  const input = 'y'.repeat(150000);
  const result = cp.spawnSync('windowed', [], { input });
  assert.equal(result.error, undefined, `no error: ${result.error && result.error.message}`);
  assert.equal(result.stdout.length, input.length, 'echo length matches');
  assert.equal(result.stdout, input, 'all input delivered in order despite the small window');
});

test('cp: spawnSync stalls loudly (EAGAIN) when the window closes and nothing moves', async () => {
  const { server } = await session;
  server.on('spawn', (proc) => {
    proc.window = 0; // closed window, child produces nothing, never exits
  });
  const result = cp.spawnSync('staller', [], { input: 'data that cannot be sent' });
  assert.ok(result.error, 'error reported instead of hanging');
  assert.equal(result.error.code, 'EAGAIN');
  assert.match(result.error.message, /stalled/);
});

test('cp: spawnSync signal exit propagates', async () => {
  const { server } = await session;
  server.once('stdinEnd', (proc) => {
    server.exitProcess(proc.pid, null, 'SIGKILL');
  });
  const result = cp.spawnSync('killed-child', []);
  assert.equal(result.status, null);
  assert.equal(result.signal, 'SIGKILL');
});

test('cp: execSync returns stdout, and throws with status on nonzero exit', async () => {
  const { server } = await session;
  let observedArgv = null;
  server.once('spawn', (proc, body) => {
    observedArgv = body.argv;
    server.queueOutput(proc.pid, 'stdout', Buffer.from('sync-exec-out'));
    server.exitProcess(proc.pid, 0, null);
  });
  const out = cp.execSync('show-thing --verbose');
  assert.deepEqual(observedArgv, ['/bin/sh', '-c', 'show-thing --verbose'], 'execSync uses the shell argv');
  assert.equal(out, 'sync-exec-out');

  server.once('spawn', (proc) => {
    server.queueOutput(proc.pid, 'stderr', Buffer.from('nope'));
    server.exitProcess(proc.pid, 3, null);
  });
  assert.throws(
    () => cp.execSync('doomed-thing'),
    (err) => {
      assert.equal(err.status, 3, 'nonzero status surfaces on the thrown error');
      assert.equal(err.stderr, 'nope');
      return true;
    }
  );
});
