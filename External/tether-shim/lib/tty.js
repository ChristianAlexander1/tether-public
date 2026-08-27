'use strict';

function isatty(fd) {
  if (process.env.TETHER_INTERACTIVE === '1' || process.env.TETHER_INTERACTIVE === 'true') {
    if (fd === 0 || fd === 1 || fd === 2 || fd == null) return true;
    return true;
  }
  return false;
}

function applyRawMode(mode) {
  try {
    const ipc = require('./ipc');
    if (typeof ipc.roundTrip !== 'function') return;
    ipc.roundTrip({ kind: 'tty', op: 'setRawMode', mode: !!mode });
  } catch (_) {
    /* Host / unit tests may not have IPC — flag-only fallback. */
  }
}

function liveWindowSize(fallbackCols, fallbackRows) {
  try {
    const ipc = require('./ipc');
    if (typeof ipc.roundTrip !== 'function') return [fallbackCols, fallbackRows];
    const reply = ipc.roundTrip({ kind: 'tty', op: 'windowSize' });
    if (reply && reply.ok && reply.cols > 0 && reply.rows > 0) {
      return [Number(reply.cols), Number(reply.rows)];
    }
  } catch (_) { /* ignore */ }
  return [fallbackCols, fallbackRows];
}

class ReadStream {
  constructor(fd) {
    this.fd = fd;
    this.isRaw = false;
    this.isTTY = isatty(fd);
  }
  setRawMode(mode) {
    this.isRaw = !!mode;
    applyRawMode(mode);
    return this;
  }
}

class WriteStream {
  constructor(fd) {
    this.fd = fd;
    this.isTTY = isatty(fd);
    const envCols = Number.parseInt(process.env.COLUMNS || '80', 10);
    const envRows = Number.parseInt(process.env.LINES || '24', 10);
    const live = liveWindowSize(envCols, envRows);
    this.columns = live[0];
    this.rows = live[1];
  }
  getWindowSize() {
    const live = liveWindowSize(this.columns, this.rows);
    this.columns = live[0];
    this.rows = live[1];
    return [this.columns, this.rows];
  }
  getColorDepth() {
    return 8;
  }
  hasColors(count) {
    return (count || 2) <= 256;
  }
}

module.exports = {
  isatty,
  ReadStream,
  WriteStream,
};
