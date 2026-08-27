'use strict';

// Default actions and the fatal path, observed through REAL node
// subprocesses (exit codes cannot be asserted from inside the dying
// process). The shim itself is NOT installed in this test process — these
// are the only tests that spawn real children, and each child runs its own
// in-process mock server, so no real sockets are used anywhere.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const cp = require('node:child_process');

const FIXTURES = path.join(__dirname, 'fixtures');

function runFixture(name, args = [], env = {}) {
  return new Promise((resolve, reject) => {
    const child = cp.spawn(process.execPath, [path.join(FIXTURES, name), ...args], {
      env: { ...process.env, ...env, TETHER_FIXTURE_ARM: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

test('default action: tty.signal SIGINT with no listener → exit 130 (edge 12)', { timeout: 20000 }, async () => {
  const result = await runFixture('signal-exit.js', ['SIGINT']);
  assert.equal(result.code, 130, `expected 128+2; stderr: ${result.stderr}`);
  assert.equal(result.signal, null);
  assert.equal(result.stdout.includes('survived'), false, 'process did not survive');
});

test('default action: tty.signal SIGTERM with no listener → exit 143', { timeout: 20000 }, async () => {
  const result = await runFixture('signal-exit.js', ['SIGTERM']);
  assert.equal(result.code, 143, `expected 128+15; stderr: ${result.stderr}`);
});

test('default action: SIGINT with a listener delivers and does not exit', { timeout: 20000 }, async () => {
  const result = await runFixture('signal-exit.js', ['SIGINT', 'listen']);
  assert.equal(result.code, 0, `stderr: ${result.stderr}`);
  assert.equal(result.stdout.trim(), 'handled');
});

test('default action: SIGTERM with a listener delivers and does not exit', { timeout: 20000 }, async () => {
  const result = await runFixture('signal-exit.js', ['SIGTERM', 'listen']);
  assert.equal(result.code, 0, `stderr: ${result.stderr}`);
  assert.equal(result.stdout.trim(), 'handled');
});

test('default action: SIGTSTP/SIGCONT/SIGHUP with no listener are no-ops (exit 0)', { timeout: 20000 }, async () => {
  for (const sig of ['SIGTSTP', 'SIGCONT', 'SIGHUP']) {
    const result = await runFixture('signal-exit.js', [sig]);
    assert.equal(result.code, 0, `${sig}: expected no-op survival; stderr: ${result.stderr}`);
    assert.equal(result.stdout.trim(), 'survived', `${sig}: process reached the fallback exit`);
  }
});

test('fatal path: protocol error → one stderr line + exit 1', { timeout: 20000 }, async () => {
  const result = await runFixture('fatal-exit.js', []);
  assert.equal(result.code, 1, `expected exit 1; got ${result.code}, stderr: ${result.stderr}`);
  const lines = result.stderr.split('\n').filter((l) => l.includes('tether-shim: IPC connection lost'));
  assert.equal(lines.length, 1, 'exactly one clear fatal line on stderr');
  assert.equal(result.stdout.includes('still-alive'), false, 'process did not linger');
});
