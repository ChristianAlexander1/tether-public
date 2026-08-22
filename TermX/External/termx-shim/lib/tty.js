'use strict';

/**
 * lib/tty.js — isatty overrides. The app tells us whether it is attached to a
 * real terminal via TERMX_INTERACTIVE; only fds 0/1/2 are reported as TTYs.
 * ReadStream / WriteStream stay as real-tty passthroughs.
 */

const real = require('tty');
const ipc = require('./ipc');

module.exports = Object.assign({}, real, {
  isatty(fd) {
    return (fd === 0 || fd === 1 || fd === 2) && ipc.isInteractive();
  },
  isTTY: ipc.isInteractive(),
  ReadStream: real.ReadStream,
  WriteStream: real.WriteStream,
});
