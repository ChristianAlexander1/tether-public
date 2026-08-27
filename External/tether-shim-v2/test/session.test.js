'use strict';

// beginSession()/endSession(): the persistent-engine lifecycle. One process
// runs many jobs, each against a fresh server (new socket per job on the
// host side), so the shim must be able to open, tear down, and reopen its
// session — with state, patches, and the fatal handler scoped per session.

const test = require('node:test');
const assert = require('node:assert/strict');

const shim = require('../lib');
const { MockServer } = require('./harness/mock-server');
const { until } = require('./helpers');

test('beginSession: connects, patches, and swaps state on the next session', async () => {
  shim._resetForTests();

  // Job 1: interactive (all three fds are a PTY).
  const serverA = new MockServer({ ttyFds: [0, 1, 2], cols: 100, rows: 40 });
  const first = await shim.beginSession({ connect: () => serverA.createConnection() });
  assert.deepEqual(first.handshake.ttyFds, [0, 1, 2]);
  const tty = require('tty');
  assert.equal(tty.isatty(1), true, 'job 1 stdout is a TTY');
  assert.equal(shim.getState().handshake.cols, 100);

  // Job 2 on a fresh server: piped stdout. The old session must be gone and
  // TTY truth must come from the NEW handshake, not the stale one.
  const serverB = new MockServer({ ttyFds: [0], cols: 80, rows: 24 });
  const second = await shim.beginSession({ connect: () => serverB.createConnection() });
  assert.notEqual(first.client, second.client, 'a new client per session');
  assert.equal(first.client.dead, true, 'previous client disposed');
  assert.equal(require('tty').isatty(1), false, 'job 2 stdout is honest: not a TTY');
  assert.equal(require('tty').isatty(0), true);
  assert.equal(serverA.hellos.length, 1);
  assert.equal(serverB.hellos.length, 1, 'exactly one handshake per session');

  shim._resetForTests();
});

test('endSession: detaches patches, disposes the client, never calls the fatal handler', async () => {
  shim._resetForTests();
  let fatalReason = null;
  const server = new MockServer({ ttyFds: [0, 1, 2] });
  const { client } = await shim.beginSession({
    connect: () => server.createConnection(),
    onFatal: (reason) => { fatalReason = reason; },
  });

  shim.endSession();

  assert.equal(client.dead, true, 'client disposed');
  assert.equal(fatalReason, null, 'deliberate teardown is not a connection loss');
  assert.equal(shim.getState(), null);
  assert.equal(shim.ready(), null, 'ready() is null between sessions');
  assert.equal(require('tty').isatty(1), false, 'no session → no TTY claims');

  // Idempotent.
  shim.endSession();
  assert.equal(shim.getState(), null);
});

test('endSession during an in-flight handshake supersedes it without attaching', async () => {
  shim._resetForTests();
  const server = new MockServer({ ttyFds: [0, 1, 2] });

  // Delay the hello response so the handshake is still pending when
  // endSession runs.
  let releaseHello;
  const released = new Promise((resolve) => { releaseHello = resolve; });
  server.hook('hello', async (body) => {
    await released;
    return server._defaultHandler('hello', body);
  });

  const pending = shim.beginSession({ connect: () => server.createConnection() });
  shim.endSession();
  releaseHello();

  await assert.rejects(pending, /superseded/);
  assert.equal(shim.getState(), null, 'a superseded session must not attach');

  shim._resetForTests();
});

test('a lost connection invokes the per-session fatal handler (job-scoped, not process exit)', async () => {
  shim._resetForTests();
  let fatalReason = null;
  const server = new MockServer({ ttyFds: [0, 1, 2] });
  const { client } = await shim.beginSession({
    connect: () => server.createConnection(),
    onFatal: (reason) => { fatalReason = reason; },
  });

  client.stream.destroy();
  await until(() => fatalReason !== null);
  assert.match(String(fatalReason), /closed/);
  assert.equal(client.dead, true);

  // A fresh session still works after the failure.
  const serverB = new MockServer({ ttyFds: [0] });
  const next = await shim.beginSession({ connect: () => serverB.createConnection() });
  assert.equal(next.client.dead, false);

  shim._resetForTests();
});
