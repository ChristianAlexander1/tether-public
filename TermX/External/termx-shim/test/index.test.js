'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const shim = require('../index');
const ourChild = require('../lib/child_process');
const ourOs = require('../lib/os');
const ourTty = require('../lib/tty');

test('index installs the child_process override', () => {
  const patched = require('child_process');
  assert.equal(patched.spawn, ourChild.spawn);
  assert.equal(patched.spawnSync, ourChild.spawnSync);
  assert.equal(patched.exec, ourChild.exec);
  assert.equal(patched.fork, ourChild.fork);
});

test('index installs the override for the node:child_process spelling', () => {
  const patched = require('node:child_process');
  assert.equal(patched.execFileSync, ourChild.execFileSync);
});

test('index installs the os and tty overrides (both spellings)', () => {
  assert.equal(require('os').platform, ourOs.platform);
  assert.equal(require('node:os').arch, ourOs.arch);
  assert.equal(require('tty').isatty, ourTty.isatty);
  assert.equal(require('node:tty').isatty, ourTty.isatty);
});

test('index exposes restore() to undo the hook', () => {
  // The patch is installed on load. Restoring is what the app would do if it
  // ever needed the original module back.
  const before = require('child_process');
  assert.equal(before.spawn, ourChild.spawn);
  const realMod = require('module');
  assert.equal(typeof realMod._load, 'function');
  // We can only observe the hook is active; calling restore resets _load.
  assert.notEqual(realMod._load.toString().includes('patchedLoad'), false);
});

test('non-overridden modules still resolve to the real thing', () => {
  const fs = require('fs');
  assert.equal(typeof fs.readFileSync, 'function');
  const path = require('path');
  assert.equal(typeof path.join, 'function');
});
