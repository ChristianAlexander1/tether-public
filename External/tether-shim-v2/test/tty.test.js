'use strict';

// tty domain: isatty truth from the handshake only, ReadStream/WriteStream
// behavior, the getColorDepth/hasColors decision matrix, and the raw-mode
// synchronous bridge with async reconciliation.

const test = require('node:test');
const assert = require('node:assert/strict');

const { setup, settle, shim } = require('./helpers');

// Handshake: fd 0 and fd 2 are PTY-bound, fd 1 is a pipe — the exact mix
// `claude | tee log` produces. cols/rows/colorTerm chosen for the matrix.
const session = setup({
  ttyFds: [0, 2],
  cols: 100,
  rows: 40,
  colorTerm: 'truecolor',
});

test('tty: isatty comes only from handshake.ttyFds (edge 1: ttyFds [0,2])', async () => {
  await session;
  const tty = require('../lib/tty');
  assert.equal(tty.isatty(0), true, 'fd 0 is PTY-bound');
  assert.equal(tty.isatty(1), false, 'fd 1 is a pipe → not a TTY');
  assert.equal(tty.isatty(2), true, 'fd 2 is PTY-bound');
  assert.equal(tty.isatty(3), false, 'fd outside 0–2 → false');
});

test('tty: isatty rejects non-numeric, negative, fractional, and unknown fds', async () => {
  await session;
  const tty = require('../lib/tty');
  assert.equal(tty.isatty('0'), false, 'string fd → false');
  assert.equal(tty.isatty(-1), false, 'negative fd → false');
  assert.equal(tty.isatty(0.5), false, 'fractional fd → false');
  assert.equal(tty.isatty(NaN), false, 'NaN → false');
  assert.equal(tty.isatty(undefined), false, 'undefined → false');
  assert.equal(tty.isatty(null), false, 'null → false');
  assert.equal(tty.isatty(99), false, 'unknown fd → false');
});

test('tty: no env flag can influence isatty', async () => {
  await session;
  const tty = require('../lib/tty');
  const saved = { ...process.env };
  process.env.TTY = '1';
  process.env.FORCE_TTY = '1';
  process.env.TERM = 'xterm-256color';
  try {
    assert.equal(tty.isatty(1), false, 'fd 1 stays non-TTY despite env');
    assert.equal(tty.isatty(0), true);
  } finally {
    process.env = saved;
  }
});

test('tty: ReadStream derives isTTY from the handshake and starts cooked', async () => {
  await session;
  const tty = require('../lib/tty');
  const raw = new tty.ReadStream(0);
  const piped = new tty.ReadStream(1);
  assert.equal(raw.isTTY, true);
  assert.equal(raw.isRaw, false, 'isRaw starts false');
  assert.equal(piped.isTTY, false);
  raw.destroy();
  piped.destroy();
});

test('tty: setRawMode on a non-TTY fd throws EINVAL synchronously (edge 4)', async () => {
  await session;
  const tty = require('../lib/tty');
  const piped = new tty.ReadStream(1);
  assert.throws(
    () => piped.setRawMode(true),
    (err) => {
      assert.equal(err.code, 'EINVAL', 'error shape matches Node: err.code === EINVAL');
      assert.match(err.message, /setRawMode/);
      return true;
    }
  );
  assert.equal(piped.isRaw, false, 'failed call leaves isRaw untouched');
  piped.destroy();
});

test('tty: setRawMode returns this and flips isRaw optimistically, server sees the req', async () => {
  const { server } = await session;
  const tty = require('../lib/tty');
  const stream = new tty.ReadStream(0);

  const returned = stream.setRawMode(true);
  assert.equal(returned, stream, 'returns this (Node signature)');
  assert.equal(stream.isRaw, true, 'optimistic local state flips immediately');

  await settle(); // let the req/res round trip complete
  const reqs = server.requestsOfType('tty.setRawMode');
  assert.equal(reqs.length, 1);
  assert.deepEqual(reqs[0].body, { fd: 0, mode: true });
  assert.equal(server.isRaw.get(0), true, 'server-side raw mode applied');
  assert.equal(stream.isRaw, true, 'stays raw after successful reconciliation');

  // Toggle back off.
  stream.setRawMode(false);
  await settle();
  assert.equal(stream.isRaw, false);
  assert.equal(server.isRaw.get(0), false);
  stream.destroy();
});

test('tty: setRawMode reconciliation failure rolls back isRaw and emits error (edge 4)', async () => {
  const { server } = await session;
  const tty = require('../lib/tty');
  const stream = new tty.ReadStream(0);
  server.failOnce('tty.setRawMode', { code: 'EINVAL', message: 'device refused' });

  const errors = [];
  stream.on('error', (err) => errors.push(err));

  stream.setRawMode(true);
  assert.equal(stream.isRaw, true, 'optimistic flip happens before the reply');

  await settle();
  assert.equal(stream.isRaw, false, 'rolled back after the server rejected');
  assert.equal(errors.length, 1, 'exactly one error emitted');
  assert.equal(errors[0].code, 'EINVAL');
  stream.destroy();
});

test('tty: WriteStream takes columns/rows from the handshake', async () => {
  await session;
  const tty = require('../lib/tty');
  const ws = new tty.WriteStream(2);
  assert.equal(ws.isTTY, true);
  assert.equal(ws.columns, 100);
  assert.equal(ws.rows, 40);
  assert.deepEqual(ws.getWindowSize(), [100, 40]);
  ws.destroy();
});

test('tty: WriteStream on a non-TTY fd is not registered and reports isTTY false', async () => {
  const { server } = await session;
  const tty = require('../lib/tty');
  const ws = new tty.WriteStream(1); // fd 1 is a pipe in this handshake
  assert.equal(ws.isTTY, false);
  const state = shim.getState();
  assert.equal(state.liveStreams().includes(ws), false, 'non-TTY streams skip the resize registry');
  server.resize(70, 30);
  await settle();
  assert.equal(ws.columns, 100, 'unregistered stream is untouched by resize');
  ws.destroy();
});

test('tty: process.stdin/stdout isTTY mirror ttyFds [0,2] (edge 1, piped stdout)', async () => {
  await session;
  assert.equal(process.stdin.isTTY, true);
  assert.equal(process.stdout.isTTY, false, 'piped stdout with interactive stdin');
  assert.equal(process.stderr.isTTY, true);
  assert.equal(typeof process.stdin.setRawMode, 'function');
  assert.equal(process.stdin.isRaw, false);
});

test('tty: process.stdin.setRawMode bridges to the wire', async () => {
  const { server } = await session;
  const returned = process.stdin.setRawMode(true);
  assert.equal(returned, process.stdin, 'returns the stream, like Node');
  assert.equal(process.stdin.isRaw, true);
  await settle();
  assert.equal(server.isRaw.get(0), true);
  process.stdin.setRawMode(false);
  await settle();
  assert.equal(process.stdin.isRaw, false);
});

// ------------------------------------------------------------- color matrix

// The matrix needs different handshake colorTerm values; attach() with
// synthetic contexts isolates getColorDepth from the installed session, then
// the real state is restored.

function fakeState(colorTerm, ttyFds = [1]) {
  return {
    handshake: { colorTerm, ttyFds, cols: 80, rows: 24 },
    client: null,
    addStream() {},
    removeStream() {},
    liveStreams: () => [],
  };
}

test('tty: getColorDepth matrix — every colorTerm × env override (edge 3)', async () => {
  await session;
  const tty = require('../lib/tty');
  const realState = shim.getState();

  const expectations = {
    truecolor: { none: 24, NO_COLOR: 1, FORCE3: 24 },
    256: { none: 8, NO_COLOR: 1, FORCE3: 24 },
    16: { none: 4, NO_COLOR: 1, FORCE3: 24 },
    none: { none: 1, NO_COLOR: 1, FORCE3: 24 },
  };

  try {
    for (const colorTerm of ['truecolor', '256', '16', 'none']) {
      tty.attach(fakeState(colorTerm));
      const want = expectations[colorTerm];
      assert.equal(tty.getColorDepth({ TERM: 'xterm-256color' }), want.none, `colorTerm=${colorTerm}, no override`);
      assert.equal(tty.getColorDepth({ NO_COLOR: '1', TERM: 'xterm-256color' }), want.NO_COLOR, `colorTerm=${colorTerm}, NO_COLOR`);
      assert.equal(tty.getColorDepth({ FORCE_COLOR: '3', TERM: 'xterm-256color' }), want.FORCE3, `colorTerm=${colorTerm}, FORCE_COLOR=3`);
    }
  } finally {
    tty.attach(realState);
  }
});

test('tty: FORCE_COLOR levels 0/1/2 map to depths 1/4/8', async () => {
  await session;
  const tty = require('../lib/tty');
  const realState = shim.getState();
  try {
    tty.attach(fakeState('none'));
    assert.equal(tty.getColorDepth({ FORCE_COLOR: '0' }), 1);
    assert.equal(tty.getColorDepth({ FORCE_COLOR: '1' }), 4);
    assert.equal(tty.getColorDepth({ FORCE_COLOR: '2' }), 8);
    assert.equal(tty.getColorDepth({ FORCE_COLOR: '' }), 4, "bare FORCE_COLOR behaves like '1'");
    assert.equal(tty.getColorDepth({ FORCE_COLOR: 'true' }), 4);
  } finally {
    tty.attach(realState);
  }
});

test('tty: NODE_DISABLE_COLORS and TERM=dumb fall back to depth 1', async () => {
  await session;
  const tty = require('../lib/tty');
  const realState = shim.getState();
  try {
    tty.attach(fakeState('truecolor'));
    assert.equal(tty.getColorDepth({ NODE_DISABLE_COLORS: '1' }), 1);
    assert.equal(tty.getColorDepth({ TERM: 'dumb' }), 1);
  } finally {
    tty.attach(realState);
  }
});

test('tty: non-TTY stdout yields depth 1 without FORCE_COLOR (piped case)', async () => {
  await session;
  const tty = require('../lib/tty');
  const realState = shim.getState();
  try {
    tty.attach(fakeState('truecolor', [0])); // fd 1 not a TTY
    assert.equal(tty.getColorDepth({ TERM: 'xterm-256color' }), 1, 'piped stdout → 1');
    assert.equal(tty.getColorDepth({ FORCE_COLOR: '3' }), 24, 'FORCE_COLOR overrides the tty check');
  } finally {
    tty.attach(realState);
  }
});

test('tty: hasColors is consistent with getColorDepth (2**depth >= count)', async () => {
  await session;
  const tty = require('../lib/tty');
  const realState = shim.getState();
  try {
    // Explicit env: the ambient process.env of the test runner (NO_COLOR,
    // TERM=dumb in some sandboxes) must not decide these assertions.
    const env = { TERM: 'xterm-256color' };
    tty.attach(fakeState('truecolor'));
    assert.equal(tty.hasColors(16, env), true);
    assert.equal(tty.hasColors(256, env), true);
    assert.equal(tty.hasColors(2 ** 24, env), true);
    assert.equal(tty.hasColors(2 ** 24 + 1, env), false);
    tty.attach(fakeState('256'));
    assert.equal(tty.hasColors(256, env), true);
    assert.equal(tty.hasColors(257, env), false);
    tty.attach(fakeState('none'));
    assert.equal(tty.hasColors(3, env), false, 'depth 1 → only 2 colors');
    assert.equal(tty.hasColors(2, env), true, '2**1 >= 2 holds at depth 1');
    assert.equal(tty.hasColors(1, env), true, '2**1 >= 1 holds even at depth 1');
  } finally {
    tty.attach(realState);
  }
});

test('tty: WriteStream.getColorDepth uses the stream fd, module fn uses stdout', async () => {
  await session;
  const tty = require('../lib/tty');
  const ws = new tty.WriteStream(2); // fd 2 IS a tty in this handshake
  assert.equal(ws.getColorDepth({ TERM: 'xterm-256color' }), 24, 'tty fd 2 → truecolor depth');
  // fd 1 is piped in this session, so the stdout-based module fn says 1.
  assert.equal(tty.getColorDepth({ TERM: 'xterm-256color' }), 1);
  assert.equal(ws.hasColors(256, { TERM: 'xterm-256color' }), true);
  ws.destroy();
});

// Regression: Ink enters raw mode as
//   stdin.ref(); stdin.setRawMode(true); stdin.addListener('readable', …)
// in one comma expression. A missing ref() threw before either of the other
// two ran, so Claude Code mounted with no input listener and never wrote a
// frame — a blank terminal with no error anywhere.
test('tty: ReadStream carries the net.Socket ref/unref/destroySoon surface', async () => {
  await session;
  const tty = require('../lib/tty');
  const stdin = new tty.ReadStream(0);
  assert.equal(typeof stdin.ref, 'function', 'ref() must exist');
  assert.equal(typeof stdin.unref, 'function', 'unref() must exist');
  assert.equal(typeof stdin.destroySoon, 'function', 'destroySoon() must exist');
  assert.equal(stdin.ref(), stdin, 'ref() is chainable');
  assert.equal(stdin.unref(), stdin, 'unref() is chainable');
  // The full Ink raw-mode entry sequence must complete without throwing.
  stdin.setEncoding('utf8');
  stdin.ref();
  stdin.setRawMode(true);
  stdin.addListener('readable', () => {});
  assert.equal(stdin.isRaw, true, 'raw mode was reached, not skipped by a throw');
  stdin.destroy();
});

test('tty: process.stdin exposes ref/unref once the live stdin is installed', async () => {
  await session;
  assert.equal(typeof process.stdin.ref, 'function', 'process.stdin.ref() must exist');
  assert.equal(typeof process.stdin.unref, 'function', 'process.stdin.unref() must exist');
  assert.equal(process.stdin.ref(), process.stdin, 'ref() is chainable');
});

test('tty: WriteStream writes its bytes to the fd instead of discarding them', async () => {
  await session;
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const tty = require('../lib/tty');
  const file = path.join(os.tmpdir(), `tether-tty-write-${process.pid}.txt`);
  const fd = fs.openSync(file, 'w+');
  try {
    const out = new tty.WriteStream(fd);
    out.write('frame-one');
    out.write(Buffer.from('[?25l'));
    assert.equal(fs.readFileSync(file, 'utf8'), 'frame-one[?25l',
      'bytes reach the descriptor; a discarding _write is a silent black hole');
    assert.equal(typeof out.ref, 'function', 'ref() must exist');
    assert.equal(out.unref(), out, 'unref() is chainable');
  } finally {
    fs.closeSync(fd);
    fs.rmSync(file, { force: true });
  }
});
