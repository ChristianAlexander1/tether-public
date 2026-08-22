'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('../lib/os');

test('os.platform() returns darwin', () => {
  assert.equal(os.platform(), 'darwin');
});

test('os.type() returns Darwin', () => {
  assert.equal(os.type(), 'Darwin');
});

test('os.arch() returns arm64', () => {
  assert.equal(os.arch(), 'arm64');
});

test('os.homedir() uses HOME', () => {
  const old = process.env.HOME;
  process.env.HOME = '/fake/home';
  try {
    assert.equal(os.homedir(), '/fake/home');
  } finally {
    if (old === undefined) delete process.env.HOME;
    else process.env.HOME = old;
  }
});

test('os.tmpdir() uses TMPDIR', () => {
  const old = process.env.TMPDIR;
  process.env.TMPDIR = '/fake/tmp';
  try {
    assert.equal(os.tmpdir(), '/fake/tmp');
  } finally {
    if (old === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = old;
  }
});

test('os.release/cpus/totalmem/freemem/endianness/EOL return sane values', () => {
  assert.equal(typeof os.release(), 'string');
  assert.ok(os.release().length > 0);
  const cpus = os.cpus();
  assert.ok(Array.isArray(cpus) && cpus.length >= 1);
  assert.ok(cpus[0].model && cpus[0].speed && cpus[0].times);
  const total = os.totalmem();
  const free = os.freemem();
  assert.ok(Number.isFinite(total) && total > 0);
  assert.ok(Number.isFinite(free) && free > 0);
  assert.equal(os.endianness(), 'LE');
  assert.equal(os.EOL, '\n');
});

test('os passthrough keeps the real endianness/networkInterfaces/constants', () => {
  // These are not overridden; they should still exist and behave.
  assert.equal(typeof os.constants, 'object');
  assert.equal(typeof os.hostname, 'function');
});
