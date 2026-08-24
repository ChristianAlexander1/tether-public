'use strict';

/** Minimal P3 host: accepts the JSON spawn request and returns a deterministic result. */
class MockHost {
  constructor() { this.requests = []; this.cancelled = new Set(); }
  handle(message) {
    if (!message || typeof message !== 'object') throw new TypeError('IPC message must be an object');
    if (message.kind === 'cancel') { this.cancelled.add(message.id); return { kind: 'exit', id: message.id, code: 130 }; }
    if (message.kind !== 'spawn') throw new Error(`unsupported IPC kind: ${message.kind}`);
    if (typeof message.file !== 'string' || !Array.isArray(message.args)) throw new TypeError('invalid spawn request');
    this.requests.push(message);
    return { kind: 'exit', code: 0, file: message.file };
  }
}
module.exports = { MockHost };
