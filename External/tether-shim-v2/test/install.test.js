'use strict';

// install(): connection defaults, idempotency (edge 13), Module._load
// interception of 'tty'/'child_process' (incl. node: prefixes), request-id
// discipline, unknown evt/req handling (edge 10 + ENOSYS), end-to-end framing
// edge cases (edge 9), fatal protocol paths, robustness against a replaced
// process.stdout.write (edge 14), and the acceptance greps.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const shim = require('../lib');
const { MockServer } = require('./harness/mock-server');
const { encodeFrame } = require('../lib/ipc/framing');
const { settle, until } = require('./helpers');

// ---------------------------------------------------------------- 1st: no connect, no env

test('install: without connect() and without TETHER_IPC_SOCK it rejects loudly', async () => {
  delete process.env.TETHER_IPC_SOCK;
  await assert.rejects(
    () => shim.install(),
    (err) => {
      assert.match(err.message, /TETHER_IPC_SOCK/);
      return true;
    }
  );
  shim._resetForTests(); // allow the successful install below
});

// ---------------------------------------------------------------- main session

const server = new MockServer({ ttyFds: [0, 1, 2], cols: 80, rows: 24, colorTerm: 'truecolor' });
let sessionPromise = null;

test('install: handshake completes and exposes the normalized handshake', async () => {
  sessionPromise = shim.install({ connect: () => server.createConnection() });
  const { client, handshake } = await sessionPromise;
  assert.ok(client, 'client exposed');
  assert.equal(handshake.proto, 2);
  assert.deepEqual(handshake.ttyFds, [0, 1, 2]);
  assert.equal(handshake.cols, 80);
  assert.equal(handshake.rows, 24);
  assert.equal(handshake.termName, 'xterm-256color');
  assert.equal(handshake.colorTerm, 'truecolor');
  assert.deepEqual(handshake.features, ['tty', 'spawn', 'flow']);
  assert.equal(client.dead, false);
});

test('install: client speaks first with hello id 1, ids strictly increasing (edge: envelope discipline)', async () => {
  await sessionPromise;
  assert.equal(server.hellos.length, 1, 'exactly one hello');
  const helloReq = server.requestsOfType('hello')[0];
  assert.equal(helloReq.kind, 'req');
  assert.equal(helloReq.id, 1, 'ids start at 1');
  assert.equal(helloReq.v, 2);
  assert.equal(helloReq.body.proto, 2);
  assert.equal(helloReq.body.role, 'node-shim');
  assert.deepEqual(helloReq.body.features, ['tty', 'spawn', 'flow']);

  // A few more requests must use strictly increasing ids.
  const tty = require('node:tty');
  tty.applyRawMode; // touch to ensure module object is the shim
  const ws = new tty.WriteStream(1);
  await shim.getState().client.request('tty.windowSize', { fd: 1 });
  await shim.getState().client.request('tty.get', { fd: 0 });
  const ids = server.requests.map((env) => env.id);
  for (let i = 1; i < ids.length; i++) {
    assert.ok(ids[i] > ids[i - 1], `id ${ids[i]} > ${ids[i - 1]}`);
  }
  ws.destroy();
});

test('install: second install() is a no-op returning the same promise (edge 13)', async () => {
  await sessionPromise;
  const again = shim.install({ connect: () => server.createConnection() });
  assert.equal(again, sessionPromise, 'identical promise object');
  await again;
  await settle(3);
  assert.equal(server.hellos.length, 1, 'no second handshake');
  assert.equal(server.connections.length, 1, 'no second connection');
});

test("install: require('tty') and require('child_process') return the shim (incl. node: prefixes)", async () => {
  await sessionPromise;
  const Module = require('node:module');
  const tty1 = require('tty');
  const tty2 = require('node:tty');
  const cp1 = require('child_process');
  const cp2 = require('node:child_process');
  assert.equal(tty1, tty2, 'same module for both request forms');
  assert.equal(cp1, cp2);
  assert.equal(typeof tty1.isatty, 'function');
  assert.equal(typeof tty1.WriteStream, 'function');
  assert.equal(typeof cp1.spawn, 'function');
  assert.equal(typeof cp1.spawnSync, 'function');
  assert.equal(typeof cp1.exec, 'function');
  assert.equal(typeof cp1.execFile, 'function');
  assert.equal(
    typeof Module._load._tetherOriginalLoad,
    'function',
    'the active loader exposes the native link needed to synchronize ESM built-ins'
  );
  assert.notEqual(
    Module._load._tetherOriginalLoad('node:child_process', module, false),
    cp1,
    'the native link does not recurse into the TJIP CommonJS shim'
  );
  // The shim's isatty answers from the handshake, not the real fd table.
  assert.equal(tty1.isatty(0), true);
  assert.equal(tty1.isatty(7), false);
});

test('install: unknown evt type is ignored and the session stays healthy (edge 10)', async () => {
  await sessionPromise;
  server.push('future.thing', { anything: 'goes' });
  server.push('another.unknown', {});
  await settle(3);
  const state = shim.getState();
  assert.equal(state.client.dead, false, 'client alive');
  // Session still fully functional: a request round trip works afterwards.
  const res = await state.client.request('tty.windowSize', { fd: 1 });
  assert.equal(res.ok, true);
  assert.equal(res.cols, 80);
});

test('install: unknown server-initiated req is answered with ENOSYS (spec)', async () => {
  await sessionPromise;
  const resSeen = new Promise((resolve) => server.once('res', resolve));
  const id = server.sendRequest('weird.op', { a: 1 });
  const res = await resSeen;
  assert.equal(res.id, id, 'response carries the same id');
  assert.equal(res.v, 2);
  assert.equal(res.kind, 'res');
  assert.equal(res.body.ok, false);
  assert.equal(res.body.code, 'ENOSYS');
  assert.ok(typeof res.body.message === 'string');
});

test('install: two frames in one raw chunk are both dispatched (edge 9, end-to-end)', async () => {
  await sessionPromise;
  let sigwinchCount = 0;
  const listener = () => {
    sigwinchCount += 1;
  };
  process.on('SIGWINCH', listener);
  try {
    const one = encodeFrame({ v: 2, kind: 'evt', type: 'tty.resize', body: { cols: 81, rows: 25 } });
    const two = encodeFrame({ v: 2, kind: 'evt', type: 'tty.resize', body: { cols: 82, rows: 26 } });
    server.injectRaw(Buffer.concat([one, two]));
    await until(() => sigwinchCount === 2, { message: 'both resize events dispatched' });
    assert.equal(process.stdout.columns, 82, 'second frame applied last');
    assert.equal(process.stdout.rows, 26);
  } finally {
    process.off('SIGWINCH', listener);
  }
});

test('install: a frame split across 7 chunks (mid-header) still dispatches once (edge 9, end-to-end)', async () => {
  await sessionPromise;
  let sigwinchCount = 0;
  const listener = () => {
    sigwinchCount += 1;
  };
  process.on('SIGWINCH', listener);
  try {
    const frame = encodeFrame({
      v: 2,
      kind: 'evt',
      type: 'tty.resize',
      body: { cols: 111, rows: 44 },
    });
    const cuts = [2, 4, 12, 20, 30, 40, frame.length]; // first cut splits the length header
    let prev = 0;
    const pieces = [];
    for (const cut of cuts) {
      pieces.push(frame.subarray(prev, cut));
      prev = cut;
    }
    assert.equal(pieces.length, 7);
    for (let i = 0; i < 6; i++) {
      server.injectRaw(pieces[i]);
      await settle(1);
      assert.equal(sigwinchCount, 0, `nothing dispatched after piece ${i + 1}`);
    }
    server.injectRaw(pieces[6]);
    await until(() => sigwinchCount === 1, { message: 'frame completed and dispatched' });
    assert.equal(process.stdout.columns, 111);
    assert.equal(process.stdout.rows, 44);
  } finally {
    process.off('SIGWINCH', listener);
  }
});

test('install: shim keeps working when user code replaces process.stdout.write (edge 14)', async () => {
  await sessionPromise;
  const realStdoutWrite = process.stdout.write;
  const realStderrWrite = process.stderr.write;
  let userWriteCalls = 0;
  process.stdout.write = function replacedWrite(chunk, ...rest) {
    userWriteCalls += 1;
    return realStdoutWrite.call(process.stdout, chunk, ...rest);
  };
  process.stderr.write = function replacedStderrWrite() {
    return true;
  };
  try {
    const state = shim.getState();
    // Resize fan-out still reaches process.stdout...
    let resized = 0;
    const onResize = () => {
      resized += 1;
    };
    process.stdout.on('resize', onResize);
    const done = new Promise((resolve) => process.once('SIGWINCH', resolve));
    server.resize(66, 33);
    await done;
    assert.equal(process.stdout.columns, 66);
    assert.equal(process.stdout.rows, 33);
    assert.equal(resized, 1);
    process.stdout.off('resize', onResize);

    // ...and ordinary IPC requests still round-trip.
    const res = await state.client.request('tty.get', { fd: 1 });
    assert.equal(res.ok, true);
    assert.ok(userWriteCalls >= 0);
  } finally {
    process.stdout.write = realStdoutWrite;
    process.stderr.write = realStderrWrite;
  }
});

test('install: fatal on declared length > 1 MiB — pending reject, handler invoked', async () => {
  shim._resetForTests();
  const fatalServer = new MockServer({ ttyFds: [0, 1, 2] });
  const fatals = [];
  const { client } = await shim.install({
    connect: () => fatalServer.createConnection(),
    onFatal: (reason) => fatals.push(reason),
  });
  // Hook a type the server will never answer, so a request stays pending.
  fatalServer.hook('tty.get', () => new Promise(() => {}));
  const pending = client.request('tty.get', { fd: 0 });
  const rejected = assert.rejects(
    () => pending,
    (err) => {
      assert.equal(err.code, 'EPROTO');
      return true;
    }
  );

  const header = Buffer.alloc(4);
  header.writeUInt32BE(1048577, 0);
  fatalServer.injectRaw(header);
  await rejected;
  assert.equal(fatals.length, 1, 'fatal handler called once');
  assert.match(fatals[0], /exceeds max frame size/);
  assert.equal(client.dead, true);
});

test('install: connection close mid-session is fatal (never hangs, never degrades)', async () => {
  shim._resetForTests();
  const fatalServer = new MockServer({ ttyFds: [0, 1, 2] });
  const fatals = [];
  const { client } = await shim.install({
    connect: () => fatalServer.createConnection(),
    onFatal: (reason) => fatals.push(reason),
  });
  const closed = new Promise((resolve) => client.once('fatal', resolve));
  fatalServer.closeAll();
  const err = await closed;
  assert.equal(err.code, 'EPROTO');
  assert.equal(fatals.length, 1);
  assert.match(fatals[0], /connection closed/);
  assert.equal(client.dead, true);
});

// ---------------------------------------------------------------- static checks

test('acceptance: no env-flag TTY faking anywhere (no TETHER_INTERACTIVE)', () => {
  const libDir = path.join(__dirname, '..', 'lib');
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.js')) files.push(full);
    }
  };
  walk(libDir);
  assert.ok(files.length >= 7, 'all lib files scanned');
  for (const file of files) {
    const src = fs.readFileSync(file, 'utf8');
    assert.equal(src.includes('TETHER_INTERACTIVE'), false, `${file} mentions TETHER_INTERACTIVE`);
    // No other env var is consulted for TTY truth either.
    assert.equal(/process\.env\.(TTY|FORCE_TTY|IS_TTY)/.test(src), false, `${file} reads TTY env flags`);
  }
});

test('acceptance: no hardcoded program names in lib/', () => {
  const libDir = path.join(__dirname, '..', 'lib');
  const walk = (dir, out = []) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full, out);
      else if (entry.name.endsWith('.js')) out.push(full);
    }
    return out;
  };
  const forbidden = /\b(claude|inquirer|vim|nano|htop|tmux|screen|zsh|bash)\b/i;
  for (const file of walk(libDir)) {
    const src = fs.readFileSync(file, 'utf8');
    assert.equal(forbidden.test(src), false, `${file} hardcodes a program name`);
  }
  // The only shell path is the spec-mandated exec() default constant.
  const cpSrc = fs.readFileSync(path.join(libDir, 'child_process.js'), 'utf8');
  assert.match(cpSrc, /DEFAULT_SHELL = '\/bin\/sh'/);
});

test('acceptance: package.json declares zero dependencies', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
  assert.equal(pkg.name, 'tether-shim-v2');
  assert.equal(pkg.dependencies, undefined, 'no dependencies');
  assert.equal(pkg.devDependencies, undefined, 'no devDependencies');
  assert.equal(pkg.optionalDependencies, undefined, 'no optionalDependencies');
  assert.equal(pkg.peerDependencies, undefined, 'no peerDependencies');
});
