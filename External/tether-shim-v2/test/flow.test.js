'use strict';

// flow domain: backpressure and flow.ack accounting.
//   Edge 7: 1 MB of stdout in 64 KiB chunks — in-order delivery, acks total
//   exactly 1 MB, and the readable's memory never exceeds the 256 KiB window
//   when the consumer is slow (paused).
//   Edge 8: stdin window drops to 0 → write() returns false; when a later
//   response reports window > 0, 'drain' fires exactly once and queued data
//   flushes in order.

const test = require('node:test');
const assert = require('node:assert/strict');

const { setup, nextEvent, settle, until } = require('./helpers');
const cp = require('../lib/child_process');
const { FLOW_WINDOW } = require('./harness/mock-server');

const session = setup({ ttyFds: [0, 1, 2] });

test('flow: 1 MB stdout in 64 KiB chunks — order, exact ack total, bounded memory (edge 7)', async () => {
  const { server } = await session;
  const child = cp.spawn('big-producer');
  await until(() => child.pid !== undefined, { message: 'pid set' });

  // Deterministic 1 MiB pattern so ordering errors are detectable byte-wise.
  const total = 1024 * 1024;
  const want = Buffer.allocUnsafe(total);
  for (let i = 0; i < total; i++) want[i] = (i * 31 + 7) & 0xff;

  const ackedAll = new Promise((resolve) => {
    server.on('ack', (pid, bytes, running) => {
      if (pid === child.pid && running === total) resolve();
    });
  });

  server.queueOutput(child.pid, 'stdout', want); // delivered under the flow window

  // PAUSED consumer: no 'data' listener; pull one chunk at a time.
  const received = [];
  let receivedBytes = 0;
  let maxBuffered = 0;
  while (receivedBytes < total) {
    await until(
      () => child.stdout.readableLength > 0 || child.stdout.readableEnded,
      { message: 'next chunk available' }
    );
    let chunk;
    while ((chunk = child.stdout.read()) !== null) {
      received.push(chunk);
      receivedBytes += chunk.length;
      const buffered = child.stdout._tetherBuffered();
      if (buffered > maxBuffered) maxBuffered = buffered;
      assert.ok(
        buffered <= FLOW_WINDOW,
        `readable holds ${buffered} bytes, window is ${FLOW_WINDOW}`
      );
    }
  }

  await ackedAll;
  assert.equal(receivedBytes, total, 'all 1 MB delivered');
  assert.equal(Buffer.concat(received).equals(want), true, 'delivered in exact order');
  assert.equal(server.totalAcked(child.pid), total, 'flow.ack totals exactly 1 MB');
  assert.equal(maxBuffered <= FLOW_WINDOW, true, `peak buffered ${maxBuffered} <= window`);

  // Finish cleanly. Note: 'end' (and therefore 'close') needs the EOF to be
  // consumed — same contract as real Node — so resume the manually-read
  // stream before awaiting close.
  const closed = nextEvent(child, 'close');
  child.stdout.resume();
  child.stderr.resume();
  server.exitProcess(child.pid, 0, null);
  await closed;
  assert.equal(server.totalAcked(child.pid), total, 'no extra acks after EOF');
});

test('flow: acks are only sent after chunks are consumed (slow consumer gates the server)', async () => {
  const { server } = await session;
  const child = cp.spawn('gated-producer');
  await until(() => child.pid !== undefined, { message: 'pid set' });

  const chunk = Buffer.alloc(65536, 0x41);
  let acksSeen = 0;
  server.on('ack', (pid) => {
    if (pid === child.pid) acksSeen += 1;
  });

  server.queueOutput(child.pid, 'stdout', chunk);
  await until(() => child.stdout.readableLength > 0, { message: 'chunk buffered' });
  await settle(5);
  assert.equal(acksSeen, 0, 'nothing acked while the chunk sits unconsumed');
  assert.equal(server.totalAcked(child.pid), 0);

  const out = child.stdout.read();
  assert.equal(out.length, 65536);
  await until(() => acksSeen === 1, { message: 'ack after consumption' });
  assert.equal(server.totalAcked(child.pid), 65536, 'ack byte count matches the chunk');

  child.stdout.resume();
  child.stderr.resume();
});

test('flow: server never exceeds the window with a fully paused consumer', async () => {
  const { server } = await session;
  const child = cp.spawn('window-producer');
  await until(() => child.pid !== undefined, { message: 'pid set' });

  // 2 MB queued; the window is 256 KiB, so the mock can only push ~4 chunks.
  server.queueOutput(child.pid, 'stdout', Buffer.alloc(2 * 1024 * 1024, 0x42));
  await settle(10); // let every allowed frame land

  const proc = server.processes.get(child.pid);
  assert.ok(proc.inFlight <= FLOW_WINDOW, `in flight ${proc.inFlight} <= ${FLOW_WINDOW}`);
  assert.ok(proc.pendingOutput.length > 0, 'the rest is still queued server-side');
  assert.equal(child.stdout._tetherBuffered(), proc.inFlight, 'client buffers exactly the unacked set');

  child.stdout.resume(); // drain everything the window allows
  child.stderr.resume();
  await until(() => server.totalAcked(child.pid) > 0, { message: 'acks flowing' });
});

test('flow: stdin window 0 → write() false; window reopens → drain once, order kept (edge 8)', async () => {
  const { server } = await session;
  const child = cp.spawn('windowed-stdin');
  await until(() => child.pid !== undefined, { message: 'pid set' });
  const proc = await until(() => server.processes.get(child.pid), { message: 'proc' }).then(() =>
    server.processes.get(child.pid)
  );

  // First response will report window 0.
  server.setWindow(child.pid, 0);

  const cbResults = [];
  const wroteFirst = child.stdin.write('a', (err) => cbResults.push(['a', err ? err.code : undefined]));
  assert.equal(wroteFirst, true, 'first write accepted (window unknown yet)');
  await until(() => cbResults.length === 1, { message: 'first write acked by server' });
  assert.deepEqual(cbResults[0], ['a', undefined]);

  // Window is now known to be 0: this write must buffer and return false.
  let drains = 0;
  child.stdin.on('drain', () => {
    drains += 1;
  });
  const wroteSecond = child.stdin.write('b', (err) => cbResults.push(['b', err ? err.code : undefined]));
  assert.equal(wroteSecond, false, 'write() returns false while window <= 0');

  await settle(5);
  assert.equal(drains, 0, 'no drain while the window stays closed');
  assert.equal(Buffer.concat(proc.stdin).toString(), 'a', "'b' is still buffered client-side");

  // Server reopens the window; any pid activity triggers the queued flush.
  server.setWindow(child.pid, 65536);
  server.queueOutput(child.pid, 'stdout', Buffer.from('tick'));

  await until(() => drains === 1, { message: 'drain fired after window reopened' });
  await until(() => cbResults.length === 2, { message: 'second write completed' });
  await settle(5);
  assert.equal(drains, 1, "drain fired exactly once");
  assert.deepEqual(cbResults[1], ['b', undefined]);
  assert.equal(Buffer.concat(proc.stdin).toString(), 'ab', 'queued data flushed in order');

  child.stdout.resume();
  child.stderr.resume();
});

test('flow: exit before stdin flush → pending writes fail EPIPE, no crash (edge 6)', async () => {
  const { server } = await session;
  const unhandled = [];
  const onUnhandled = (reason) => unhandled.push(reason);
  process.on('unhandledRejection', onUnhandled);

  try {
    const child = cp.spawn('dies-early');
    await until(() => child.pid !== undefined, { message: 'pid set' });

    // Close the window so 'b' stays queued client-side, then kill the child.
    server.setWindow(child.pid, 0);
    const stdinErrors = [];
    child.stdin.on('error', (err) => stdinErrors.push(err));

    const firstDone = nextEvent(child, 'exit');
    child.stdin.write('a');
    await until(() => server.processes.get(child.pid).stdin.length === 1, {
      message: 'first write delivered',
    });

    const secondCb = new Promise((resolve) => {
      const returned = child.stdin.write('b', (err) => resolve({ returned, code: err && err.code }));
      assert.equal(returned, false, 'write buffers while window is 0');
    });

    server.exitProcess(child.pid, 0, null); // exits with 'b' still queued
    await firstDone;

    const cbResult = await secondCb;
    assert.equal(cbResult.code, 'EPIPE', 'pending write callback receives EPIPE');
    await until(() => stdinErrors.length === 1, { message: 'stdin error event' });
    assert.equal(stdinErrors[0].code, 'EPIPE');
    assert.equal(child.stdin.destroyed, true, 'writable destroyed');
    assert.equal(child.stdin.write('c', () => {}), false, 'further writes return false');

    child.stdout.resume();
    child.stderr.resume();
    await settle(5);
    assert.equal(unhandled.length, 0, 'no unhandled rejections');
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
});

test('flow: windowed writes flush in order across several responses', async () => {
  const { server } = await session;
  const child = cp.spawn('ordered-writer');
  await until(() => child.pid !== undefined, { message: 'pid set' });
  const proc = server.processes.get(child.pid);

  const writes = ['one-', 'two-', 'three-', 'four'];
  const done = [];
  for (const w of writes) {
    child.stdin.write(w, () => done.push(w));
  }
  const ended = nextEvent(server, 'stdinEnd');
  child.stdin.end();
  await ended;
  await until(() => done.length === writes.length, { message: 'all callbacks' });
  assert.deepEqual(done, writes, 'callbacks in submission order');
  assert.equal(Buffer.concat(proc.stdin).toString(), writes.join(''), 'bytes in order');
  child.stdout.resume();
  child.stderr.resume();
});
