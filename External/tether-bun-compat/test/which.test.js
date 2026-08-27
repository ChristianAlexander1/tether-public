'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createWhich } = require('../lib/which');
const { makeFakeFs } = require('./fake-fs');

const DIRS = ['/bin', '/usr/bin', '/usr/local/bin', '/opt/bin', '/home/user/.local/bin'];

function setup() {
  const fs = makeFakeFs();
  DIRS.forEach(d => fs.addDir(d));
  fs.addFile('/usr/local/bin/found-tool', { mode: 0o755, content: '#!/bin/sh\n' });
  fs.addFile('/opt/bin/found-tool', { mode: 0o755 });
  // A directory that shares a name with a command — must be skipped.
  fs.addDir('/usr/bin/found-tool');
  // Non-executable file — must be skipped.
  fs.addFile('/bin/locked-tool', { mode: 0o644 });
  // Executable in the last PATH dir to confirm we scan all 5.
  fs.addFile('/home/user/.local/bin/late-tool', { mode: 0o755 });
  const which = createWhich({ pathDirs: DIRS, fs, platform: 'linux' });
  return { fs, which };
}

test('which finds executable in 3rd of 5 dirs and returns the first match', () => {
  const { which } = setup();
  assert.equal(which('found-tool'), '/usr/local/bin/found-tool');
});

test('which skips a directory that happens to share the name', () => {
  const { which } = setup();
  // /usr/bin/found-tool exists as a dir; /usr/local/bin/found-tool is the executable.
  assert.equal(which('found-tool'), '/usr/local/bin/found-tool');
});

test('which returns null for names not present in any PATH dir', () => {
  const { which } = setup();
  assert.equal(which('zzz-definitely-not-here'), null);
});

test('which does not throw when a PATH entry does not exist', () => {
  const fs = makeFakeFs();
  fs.addDir('/real/bin');
  fs.addFile('/real/bin/tool', { mode: 0o755 });
  const which = createWhich({
    pathDirs: ['/does/not/exist', '/real/bin'],
    fs,
    platform: 'linux',
  });
  assert.equal(which('tool'), '/real/bin/tool');
});

test('which returns null for empty name without throwing', () => {
  const { which } = setup();
  assert.equal(which(''), null);
});

test('which returns null for empty PATH without throwing', () => {
  const fs = makeFakeFs();
  const which = createWhich({ pathDirs: [], fs, platform: 'linux' });
  assert.equal(which('anything'), null);
});

test('which respects options.PATH override (string, colon-delimited)', () => {
  const fs = makeFakeFs();
  fs.addDir('/a/bin');
  fs.addDir('/b/bin');
  fs.addFile('/a/bin/tool', { mode: 0o755 });
  fs.addFile('/b/bin/tool', { mode: 0o755 });
  const which = createWhich({ pathDirs: ['/b/bin'], fs, platform: 'linux' });
  assert.equal(which('tool'), '/b/bin/tool');
  assert.equal(which('tool', { PATH: '/a/bin' }), '/a/bin/tool');
});

test('which handles name containing a path separator by checking directly', () => {
  const fs = makeFakeFs();
  fs.addDir('/cwd');
  fs.addFile('/cwd/run', { mode: 0o755 });
  fs.addFile('/cwd/nope', { mode: 0o644 });
  const which = createWhich({ pathDirs: ['/usr/bin'], fs, platform: 'linux' });
  assert.equal(which('/cwd/run'), '/cwd/run');
  assert.equal(which('/cwd/nope'), null);
  assert.equal(which('./run', { cwd: '/cwd' }), '/cwd/run');
  assert.equal(which('/does/not/exist'), null);
});

test('which resolves relative PATH entries against options.cwd', () => {
  const fs = makeFakeFs();
  fs.addDir('/project/local/bin');
  fs.addFile('/project/local/bin/tool', { mode: 0o755 });
  const which = createWhich({ pathDirs: ['local/bin'], fs, platform: 'linux' });
  assert.equal(which('tool', { cwd: '/project' }), '/project/local/bin/tool');
});

test('which skips non-executable files', () => {
  const { which } = setup();
  assert.equal(which('locked-tool'), null);
});

// — the no-hardcoding proof —
// Two ARBITRARY names must go through byte-identical code paths:
// same sequence of fs.accessSync / fs.statSync calls with only the
// basename swapped. We assert that by diffing the recorded call shapes.
test('generic path code: two arbitrary names produce identical call shapes (no special-casing)', () => {
  const fs = makeFakeFs();
  DIRS.forEach(d => fs.addDir(d));
  // Neither name exists — both should scan identically and return null.
  const which = createWhich({ pathDirs: DIRS, fs, platform: 'linux' });
  const nameA = 'zzz-made-up';
  const nameB = 'claude'; // arbitrary, must NOT be special-cased

  fs.calls.accessSync.length = 0;
  fs.calls.statSync.length = 0;
  assert.equal(which(nameA), null);
  const shapeA = {
    access: fs.calls.accessSync.map(c => c.path.replace(nameA, '$')),
    stat: fs.calls.statSync.map(c => c.path.replace(nameA, '$')),
    accessModes: fs.calls.accessSync.map(c => c.mode),
    statCount: fs.calls.statSync.length,
    accessCount: fs.calls.accessSync.length,
  };

  fs.calls.accessSync.length = 0;
  fs.calls.statSync.length = 0;
  assert.equal(which(nameB), null);
  const shapeB = {
    access: fs.calls.accessSync.map(c => c.path.replace(nameB, '$')),
    stat: fs.calls.statSync.map(c => c.path.replace(nameB, '$')),
    accessModes: fs.calls.accessSync.map(c => c.mode),
    statCount: fs.calls.statSync.length,
    accessCount: fs.calls.accessSync.length,
  };

  assert.deepEqual(shapeA, shapeB,
    'lookup of two arbitrary names must traverse byte-identical code paths');
});

test('which returns null for non-string name without throwing', () => {
  const { which } = setup();
  assert.equal(which(null), null);
  assert.equal(which(undefined), null);
  assert.equal(which(42), null);
});
