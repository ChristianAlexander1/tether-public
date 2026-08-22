'use strict';

const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const tty = require('../lib/tty');

const oldInteractive = process.env.TERMX_INTERACTIVE;

beforeEach(() => {});
afterEach(() => {
  if (oldInteractive === undefined) delete process.env.TERMX_INTERACTIVE;
  else process.env.TERMX_INTERACTIVE = oldInteractive;
});

test('tty.isatty(0/1/2) is true when TERMX_INTERACTIVE=1', () => {
  process.env.TERMX_INTERACTIVE = '1';
  assert.equal(tty.isatty(0), true);
  assert.equal(tty.isatty(1), true);
  assert.equal(tty.isatty(2), true);
});

test('tty.isatty(0/1/2) is false when TERMX_INTERACTIVE=0', () => {
  process.env.TERMX_INTERACTIVE = '0';
  assert.equal(tty.isatty(0), false);
  assert.equal(tty.isatty(1), false);
  assert.equal(tty.isatty(2), false);
});

test('tty.isatty(other fds) is false even when interactive', () => {
  process.env.TERMX_INTERACTIVE = '1';
  assert.equal(tty.isatty(3), false);
  assert.equal(tty.isatty(100), false);
});

test('tty keeps ReadStream/WriteStream passthrough', () => {
  assert.equal(typeof tty.ReadStream, 'function');
  assert.equal(typeof tty.WriteStream, 'function');
});
