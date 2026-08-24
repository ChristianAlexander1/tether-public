'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');

describe('index.js Module._load patch', () => {
  it('require("os") after --require is shim darwin', () => {
    const r = spawnSync(
      process.execPath,
      ['-r', path.join(root, 'index.js'), '-e', 'console.log(require("os").platform())'],
      { encoding: 'utf8' }
    );
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), 'darwin');
  });

  it('require("node:os") is also patched', () => {
    const r = spawnSync(
      process.execPath,
      ['-r', path.join(root, 'index.js'), '-e', 'console.log(require("node:os").platform())'],
      { encoding: 'utf8' }
    );
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), 'darwin');
  });

  it('require("tty").isatty honors TETHER_INTERACTIVE', () => {
    const r = spawnSync(
      process.execPath,
      ['-r', path.join(root, 'index.js'), '-e', 'console.log(require("tty").isatty(1))'],
      { encoding: 'utf8', env: { ...process.env, TETHER_INTERACTIVE: '1' } }
    );
    assert.equal(r.stdout.trim(), 'true');
  });

  it('package exports child_process os tty ipc', () => {
    const pkg = require('..');
    assert.ok(pkg.child_process.spawn);
    assert.ok(pkg.os.platform);
    assert.ok(pkg.tty.isatty);
    assert.ok(pkg.ipc.sendRequest);
  });

  it('package.json name is @tether/shim', () => {
    const pj = require('../package.json');
    assert.equal(pj.name, '@tether/shim');
  });
});
