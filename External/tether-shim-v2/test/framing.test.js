'use strict';

// Framing: encode/decode round trips, multi-frame chunks, frames split
// across many chunks (including mid-length-header), and the fatal > 1 MiB
// declared length. Edge case 9 lives here and is additionally exercised
// end-to-end in install.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  encodeFrame,
  FrameParser,
  MAX_FRAME_BYTES,
  HEADER_BYTES,
  protocolError,
} = require('../lib/ipc/framing');

function collectingParser() {
  const frames = [];
  const parser = new FrameParser((env) => frames.push(env));
  return { frames, parser };
}

test('framing: encode produces BE uint32 length + exact JSON bytes', () => {
  const frame = encodeFrame({ v: 2, kind: 'evt', type: 'x.y', body: { a: 1 } });
  const json = Buffer.from(JSON.stringify({ v: 2, kind: 'evt', type: 'x.y', body: { a: 1 } }), 'utf8');
  assert.equal(frame.length, HEADER_BYTES + json.length);
  assert.equal(frame.readUInt32BE(0), json.length, 'length counts JSON bytes only');
  assert.deepEqual(frame.subarray(HEADER_BYTES), json);
});

test('framing: length header is big-endian', () => {
  const frame = encodeFrame({ v: 2, kind: 'evt', type: 't', body: {} });
  // "{}" payload for {v,kind,type,body:{}} is much larger than 2 bytes; just
  // verify BE ordering directly against the payload length.
  const declared = frame.readUInt32BE(0);
  const declaredLE = frame.readUInt32LE(0);
  assert.equal(declared, frame.length - HEADER_BYTES);
  assert.notEqual(declared, declaredLE, 'BE and LE readings differ for realistic sizes');
});

test('framing: round trip through the parser', () => {
  const { frames, parser } = collectingParser();
  const envelope = { v: 2, kind: 'res', id: 3, type: 'tty.get', body: { ok: true, isTTY: true } };
  parser.consume(encodeFrame(envelope));
  assert.equal(frames.length, 1);
  assert.deepEqual(frames[0], envelope);
});

test('framing: many frames in one chunk (edge 9, part 1 — batched delivery)', () => {
  const { frames, parser } = collectingParser();
  const envelopes = [];
  const chunks = [];
  for (let i = 0; i < 10; i++) {
    const env = { v: 2, kind: 'evt', type: `evt.n${i}`, body: { i } };
    envelopes.push(env);
    chunks.push(encodeFrame(env));
  }
  parser.consume(Buffer.concat(chunks)); // two (ten!) frames in one chunk
  assert.equal(frames.length, 10);
  for (let i = 0; i < 10; i++) {
    assert.deepEqual(frames[i], envelopes[i]);
  }
});

test('framing: exactly two frames in one TCP chunk (edge 9, spec wording)', () => {
  const { frames, parser } = collectingParser();
  const a = { v: 2, kind: 'evt', type: 'a.one', body: { x: 1 } };
  const b = { v: 2, kind: 'evt', type: 'b.two', body: { y: 2 } };
  parser.consume(Buffer.concat([encodeFrame(a), encodeFrame(b)]));
  assert.equal(frames.length, 2);
  assert.equal(frames[0].type, 'a.one');
  assert.equal(frames[1].type, 'b.two');
});

test('framing: one frame split across 7 chunks including mid-length-header (edge 9, part 2)', () => {
  const { frames, parser } = collectingParser();
  const envelope = { v: 2, kind: 'evt', type: 'split.test', body: { payload: 'x'.repeat(200) } };
  const frame = encodeFrame(envelope);

  // 7 pieces; the cut at byte 2 splits the 4-byte length header itself.
  const cuts = [2, 4, 40, 90, 140, 190, frame.length];
  let prev = 0;
  const pieces = [];
  for (const cut of cuts) {
    pieces.push(frame.subarray(prev, cut));
    prev = cut;
  }
  assert.equal(pieces.length, 7);
  assert.equal(pieces[0].length, 2, 'first piece is a partial length header');

  for (let i = 0; i < 6; i++) {
    parser.consume(pieces[i]);
    assert.equal(frames.length, 0, `no frame emitted after piece ${i + 1}`);
    assert.ok(parser.pendingBytes > 0, `bytes buffered after piece ${i + 1}`);
  }
  parser.consume(pieces[6]);
  assert.equal(frames.length, 1, 'frame completes exactly on the last piece');
  assert.deepEqual(frames[0], envelope);
  assert.equal(parser.pendingBytes, 0, 'no leftover bytes');
});

test('framing: byte-at-a-time delivery of two interleaved-in-time frames', () => {
  const { frames, parser } = collectingParser();
  const a = { v: 2, kind: 'evt', type: 'slow.a', body: {} };
  const b = { v: 2, kind: 'evt', type: 'slow.b', body: { big: 'y'.repeat(64) } };
  const wire = Buffer.concat([encodeFrame(a), encodeFrame(b)]);
  for (const byte of wire) {
    parser.consume(Buffer.from([byte]));
  }
  assert.equal(frames.length, 2);
  assert.equal(frames[0].type, 'slow.a');
  assert.equal(frames[1].type, 'slow.b');
});

test('framing: declared length above 1 MiB is a fatal EPROTO', () => {
  const { frames, parser } = collectingParser();
  const header = Buffer.alloc(HEADER_BYTES);
  header.writeUInt32BE(MAX_FRAME_BYTES + 1, 0);
  assert.throws(
    () => parser.consume(header),
    (err) => {
      assert.equal(err.code, 'EPROTO');
      assert.match(err.message, /exceeds max frame size/);
      return true;
    }
  );
  assert.equal(frames.length, 0);
});

test('framing: encode rejects payloads above 1 MiB with EMSGSIZE', () => {
  const huge = { v: 2, kind: 'evt', type: 'huge', body: { data: 'z'.repeat(MAX_FRAME_BYTES) } };
  assert.throws(() => encodeFrame(huge), (err) => err.code === 'EMSGSIZE');
});

test('framing: invalid JSON payload → EPROTO', () => {
  const { parser } = collectingParser();
  const bad = Buffer.alloc(HEADER_BYTES + 5);
  bad.writeUInt32BE(5, 0);
  bad.write('{oops', HEADER_BYTES);
  assert.throws(() => parser.consume(bad), (err) => err.code === 'EPROTO');
});

test('framing: non-object payload → EPROTO', () => {
  const { parser } = collectingParser();
  const arr = Buffer.from('[1,2]', 'utf8');
  const frame = Buffer.concat([Buffer.from([0, 0, 0, arr.length]), arr]);
  assert.throws(() => parser.consume(frame), (err) => err.code === 'EPROTO');
});

test('framing: wrong protocol version → EPROTO', () => {
  const { parser } = collectingParser();
  const env = { v: 1, kind: 'evt', type: 'old', body: {} };
  assert.throws(() => parser.consume(encodeFrame(env)), (err) => err.code === 'EPROTO');
});

test('framing: unknown envelope kind → EPROTO', () => {
  const { parser } = collectingParser();
  const env = { v: 2, kind: 'weird', type: 'x', body: {} };
  assert.throws(() => parser.consume(encodeFrame(env)), (err) => err.code === 'EPROTO');
});

test('framing: parser buffers across consume calls and reset() clears', () => {
  const { frames, parser } = collectingParser();
  const env = { v: 2, kind: 'evt', type: 'reset.test', body: {} };
  const frame = encodeFrame(env);
  parser.consume(frame.subarray(0, 3));
  assert.equal(parser.pendingBytes, 3);
  parser.reset();
  assert.equal(parser.pendingBytes, 0);
  parser.consume(frame);
  assert.equal(frames.length, 1);
});

test('framing: protocolError carries the requested errno code', () => {
  const err = protocolError('nope', 'ESRCH');
  assert.equal(err.code, 'ESRCH');
  assert.equal(err.message, 'nope');
  assert.ok(err instanceof Error);
});

test('framing: empty-body envelope (minimal frame) round trips', () => {
  const { frames, parser } = collectingParser();
  parser.consume(encodeFrame({ v: 2, kind: 'evt', type: 'bare', body: {} }));
  assert.equal(frames.length, 1);
  assert.deepEqual(frames[0].body, {});
});
