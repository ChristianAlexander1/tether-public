'use strict';

// TJIP/2 framing (FROZEN wire spec):
//   frame = 4-byte big-endian uint32 length N, then N bytes of UTF-8 JSON.
//   N counts the JSON bytes only. Max frame = 1,048,576 bytes; a longer
//   declared length is a fatal protocol error.
//
// FrameParser is stream-safe: a frame may arrive across many chunks, and many
// frames may arrive in one chunk.

const MAX_FRAME_BYTES = 1048576; // 1 MiB
const HEADER_BYTES = 4;

function protocolError(message, code) {
  const err = new Error(message);
  err.code = code || 'EPROTO';
  return err;
}

/**
 * Encode an envelope object into a single wire frame.
 * @param {object} envelope
 * @returns {Buffer}
 */
function encodeFrame(envelope) {
  const json = Buffer.from(JSON.stringify(envelope), 'utf8');
  if (json.length > MAX_FRAME_BYTES) {
    throw protocolError(
      `frame payload of ${json.length} bytes exceeds max frame size ${MAX_FRAME_BYTES}`,
      'EMSGSIZE'
    );
  }
  const frame = Buffer.allocUnsafe(HEADER_BYTES + json.length);
  frame.writeUInt32BE(json.length, 0);
  json.copy(frame, HEADER_BYTES);
  return frame;
}

/**
 * Incremental frame parser. Feed it arbitrary byte chunks; it calls
 * `onFrame(envelope)` for every complete, well-formed frame.
 *
 * Throws (code EPROTO) on:
 *   - declared length > MAX_FRAME_BYTES
 *   - invalid JSON
 *   - non-object frame body
 *   - missing/wrong protocol version (`v` must be 2)
 *   - unknown envelope kind (not req/res/evt)
 */
class FrameParser {
  constructor(onFrame) {
    if (typeof onFrame !== 'function') {
      throw new TypeError('FrameParser requires an onFrame callback');
    }
    this.onFrame = onFrame;
    this.buffer = Buffer.alloc(0);
  }

  /**
   * Consume a chunk of bytes. May invoke onFrame zero or more times.
   * @param {Buffer} chunk
   */
  consume(chunk) {
    if (!Buffer.isBuffer(chunk)) chunk = Buffer.from(chunk);
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);

    for (;;) {
      if (this.buffer.length < HEADER_BYTES) return;

      const declared = this.buffer.readUInt32BE(0);
      if (declared > MAX_FRAME_BYTES) {
        this.buffer = Buffer.alloc(0);
        throw protocolError(
          `declared frame length ${declared} exceeds max frame size ${MAX_FRAME_BYTES}`
        );
      }
      if (this.buffer.length < HEADER_BYTES + declared) return; // partial frame: wait

      const jsonBytes = this.buffer.subarray(HEADER_BYTES, HEADER_BYTES + declared);
      this.buffer = this.buffer.subarray(HEADER_BYTES + declared);

      let envelope;
      try {
        envelope = JSON.parse(jsonBytes.toString('utf8'));
      } catch (cause) {
        throw protocolError(`invalid JSON in frame: ${cause.message}`);
      }
      if (envelope === null || typeof envelope !== 'object' || Array.isArray(envelope)) {
        throw protocolError('frame payload is not a JSON object');
      }
      if (envelope.v !== 2) {
        throw protocolError(`unsupported protocol version: ${JSON.stringify(envelope.v)}`);
      }
      if (envelope.kind !== 'req' && envelope.kind !== 'res' && envelope.kind !== 'evt') {
        throw protocolError(`unknown envelope kind: ${JSON.stringify(envelope.kind)}`);
      }
      this.onFrame(envelope);
    }
  }

  /** Number of buffered bytes awaiting frame completion. */
  get pendingBytes() {
    return this.buffer.length;
  }

  reset() {
    this.buffer = Buffer.alloc(0);
  }
}

module.exports = {
  encodeFrame,
  FrameParser,
  protocolError,
  MAX_FRAME_BYTES,
  HEADER_BYTES,
};
