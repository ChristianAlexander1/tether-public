'use strict';

function isatty(fd) {
  if (process.env.TETHER_INTERACTIVE === '1' || process.env.TETHER_INTERACTIVE === 'true') {
    if (fd === 0 || fd === 1 || fd === 2 || fd == null) return true;
    return true;
  }
  return false;
}

class ReadStream {
  constructor(fd) {
    this.fd = fd;
    this.isRaw = false;
    this.isTTY = isatty(fd);
  }
  setRawMode(mode) {
    this.isRaw = !!mode;
    return this;
  }
}

class WriteStream {
  constructor(fd) {
    this.fd = fd;
    this.isTTY = isatty(fd);
    this.columns = Number.parseInt(process.env.COLUMNS || '80', 10);
    this.rows = Number.parseInt(process.env.LINES || '24', 10);
  }
  getWindowSize() {
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
