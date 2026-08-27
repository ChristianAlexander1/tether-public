'use strict';

// signals: tty.resize fan-out ordering (update all streams → emit 'resize'
// on each → process SIGWINCH exactly once) and tty.signal → process.emit
// with the documented no-op/default-action rules.

const test = require('node:test');
const assert = require('node:assert/strict');

const { setup, nextEvent, settle, shim } = require('./helpers');

const session = setup({ ttyFds: [0, 1, 2], cols: 80, rows: 24 });

test('signals: resize updates all 5 live WriteStreams before any event fires (edge 2)', async () => {
  const { server } = await session;
  const tty = require('../lib/tty');

  const streams = [];
  const log = [];
  let allUpdatedBeforeFirstEvent = true;
  let firstEventColumns = null;

  for (let i = 0; i < 5; i++) {
    const ws = new tty.WriteStream(1);
    ws.on('resize', () => {
      log.push(`resize-${i}`);
      if (firstEventColumns === null) {
        firstEventColumns = ws.columns;
        // The very first 'resize' already sees every stream updated.
        for (const other of streams) {
          if (other.columns !== 132 || other.rows !== 43) {
            allUpdatedBeforeFirstEvent = false;
          }
        }
      }
    });
    streams.push(ws);
  }
  assert.equal(streams.length, 5);
  for (const ws of streams) {
    assert.equal(ws.columns, 80, 'starts at handshake cols');
    assert.equal(ws.rows, 24, 'starts at handshake rows');
  }

  const sigwinch = nextEvent(process, 'SIGWINCH');
  server.resize(132, 43);
  await sigwinch;

  assert.equal(allUpdatedBeforeFirstEvent, true, 'all streams updated before the first resize event');
  assert.equal(firstEventColumns, 132);
  assert.equal(log.length, 5, "each of the 5 streams got exactly one 'resize'");
  for (let i = 0; i < 5; i++) {
    assert.equal(streams[i].columns, 132);
    assert.equal(streams[i].rows, 43);
    assert.deepEqual(streams[i].getWindowSize(), [132, 43]);
  }
  for (const ws of streams) ws.destroy();
});

test("signals: 'SIGWINCH' observed on process exactly once per resize, after 'resize' events", async () => {
  const { server } = await session;
  const tty = require('../lib/tty');

  const order = [];
  let sigwinchCount = 0;
  const onSigwinch = () => {
    sigwinchCount += 1;
    order.push('sigwinch');
  };
  process.on('SIGWINCH', onSigwinch);

  const ws = new tty.WriteStream(1);
  ws.on('resize', () => order.push('resize'));

  const done = nextEvent(process, 'SIGWINCH');
  server.resize(90, 30);
  await done;
  await settle();

  assert.equal(sigwinchCount, 1, 'SIGWINCH fired exactly once');
  assert.ok(order.indexOf('resize') < order.indexOf('sigwinch'), 'resize events precede SIGWINCH');

  process.off('SIGWINCH', onSigwinch);
  ws.destroy();
});

test('signals: resize also updates process.stdout when fd 1 is a TTY', async () => {
  const { server } = await session;
  const before = process.stdout.columns;
  const done = nextEvent(process, 'SIGWINCH');
  server.resize(before + 40, 50);
  await done;
  assert.equal(process.stdout.columns, before + 40);
  assert.equal(process.stdout.rows, 50);
  assert.deepEqual(process.stdout.getWindowSize(), [before + 40, 50]);
});

test('signals: a WriteStream constructed after a resize sees the new geometry', async () => {
  const { server } = await session;
  const done = nextEvent(process, 'SIGWINCH');
  server.resize(123, 45);
  await done;
  const tty = require('../lib/tty');
  const ws = new tty.WriteStream(1);
  assert.equal(ws.columns, 123, 'late-constructed stream uses current geometry');
  assert.equal(ws.rows, 45);
  assert.deepEqual(ws.getWindowSize(), [123, 45]);
  ws.destroy();
});

test('signals: malformed resize bodies are ignored', async () => {
  const { server } = await session;
  const tty = require('../lib/tty');
  const ws = new tty.WriteStream(1);
  const resizes = [];
  ws.on('resize', () => resizes.push(1));
  const colsBefore = ws.columns;
  const rowsBefore = ws.rows;

  server.push('tty.resize', { cols: 'wide', rows: 30 }); // non-integer
  server.push('tty.resize', {}); // missing fields
  server.push('tty.resize', { cols: 0, rows: 0 }); // non-positive
  await settle();

  assert.equal(resizes.length, 0, 'no resize emitted for malformed bodies');
  assert.equal(ws.columns, colsBefore, 'columns untouched');
  assert.equal(ws.rows, rowsBefore, 'rows untouched');
  ws.destroy();
});

test('signals: tty.signal SIGINT is delivered to a registered listener', async () => {
  const { server } = await session;
  let received = 0;
  const listener = () => {
    received += 1;
  };
  process.on('SIGINT', listener);
  try {
    server.signal('SIGINT');
    await settle();
    assert.equal(received, 1, 'listener saw SIGINT exactly once');
  } finally {
    process.off('SIGINT', listener);
  }
  // If the default action had run, this assertion would never execute.
  assert.ok(true, 'process still alive with a listener registered');
});

test('signals: tty.signal SIGTERM is delivered to a registered listener', async () => {
  const { server } = await session;
  let received = 0;
  const listener = () => {
    received += 1;
  };
  process.on('SIGTERM', listener);
  try {
    server.signal('SIGTERM');
    await settle();
    assert.equal(received, 1);
  } finally {
    process.off('SIGTERM', listener);
  }
  assert.ok(true, 'process still alive');
});

test('signals: SIGTSTP/SIGCONT/SIGHUP with no listeners are no-ops (no suspend semantics in-app)', async () => {
  const { server } = await session;
  assert.equal(process.listenerCount('SIGTSTP'), 0);
  assert.equal(process.listenerCount('SIGCONT'), 0);
  assert.equal(process.listenerCount('SIGHUP'), 0);

  server.signal('SIGTSTP');
  server.signal('SIGCONT');
  server.signal('SIGHUP');
  await settle();

  // The test process reaching this line proves none of them exited/suspended it.
  assert.equal(process.listenerCount('SIGTSTP'), 0, 'still zero listeners');
  assert.ok(true, 'process alive: unlistened stop/cont/hup are no-ops');
});

test('signals: SIGTSTP with a listener is delivered', async () => {
  const { server } = await session;
  let received = 0;
  const listener = () => {
    received += 1;
  };
  process.on('SIGTSTP', listener);
  try {
    server.signal('SIGTSTP');
    await settle();
    assert.equal(received, 1);
  } finally {
    process.off('SIGTSTP', listener);
  }
});

test('signals: unknown signal names are ignored, session stays healthy', async () => {
  const { server } = await session;
  server.signal('SIGUSR1'); // not in the spec's set → ignore
  server.signal('SIGKILL'); // cannot be emulated → ignore
  await settle();
  const state = shim.getState();
  assert.ok(state && !state.client.dead, 'client still healthy after unknown signals');
});
