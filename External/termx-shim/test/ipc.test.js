'use strict';

/**
 * End-to-end test of the real wire protocol over a Unix domain socket, with the
 * mock engine running in a separate process. This proves roundTrip against the
 * actual transport (TERMX_IPC_SOCKET), not just the in-process fake.
 */

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn: spawnProc } = require('child_process');

const ipc = require('../lib/ipc');
const cp = require('../lib/child_process');

const socketPath = path.join(os.tmpdir(), 'termx-ipc-' + process.pid + '.sock');
const backendPath = path.join(__dirname, 'mock-backend.js');

let child = null;

function waitForListening(proc, timeoutMs) {
  return new Promise((resolve, reject) => {
    let out = '';
    const timer = setTimeout(() => reject(new Error('mock backend did not start: ' + out)), timeoutMs);
    proc.stdout.on('data', (d) => {
      out += d.toString();
      if (out.includes('LISTENING')) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.stderr.on('data', (d) => (out += d.toString()));
  });
}

before(async () => {
  try { fs.unlinkSync(socketPath); } catch (_) {}
  // A real OS child process allows genuinely timing-independent I/O.
  child = spawnProc(process.execPath, [backendPath, socketPath], { stdio: ['ignore', 'pipe', 'pipe'] });
  await waitForListening(child, 5000);
  process.env.TERMX_IPC_SOCKET = socketPath;
  ipc.clearTransport(); // force env-based transport
  await ipc.connect();  // establish the socket (the one async step)
});

after(() => {
  if (child && !child.killed) child.kill('SIGTERM');
  delete process.env.TERMX_IPC_SOCKET;
  try { fs.unlinkSync(socketPath); } catch (_) {}
});

test('roundTrip sends a JSON request and receives a JSON reply over the socket', () => {
  const reply = ipc.roundTrip({ op: 'spawnSync', file: 'prog', args: [], shell: false, interactive: false });
  assert.equal(reply.exitCode, 0);
  assert.equal(reply.stdout, 'over the wire\n');
  assert.equal(reply.error, null);
});

test('spawnSync works end-to-end over the socket transport', () => {
  const r = cp.spawnSync('cat', { input: 'line1\nline2\n', encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, 'line1\nline2\n');
});

test('spawn works end-to-end over the socket transport with exit/close ordering', async () => {
  const child2 = cp.spawn('prog');
  const events = [];
  child2.stdout.on('data', (d) => events.push('data:' + d.toString()));
  child2.on('spawn', () => events.push('spawn'));
  child2.on('exit', () => events.push('exit'));
  child2.on('close', () => events.push('close'));
  await new Promise((resolve) => child2.on('close', resolve));
  assert.equal(events.indexOf('spawn'), 0);
  assert.ok(events.indexOf('exit') < events.indexOf('close'));
  assert.ok(events.includes('data:over the wire\n'));
  assert.equal(child2.exitCode, 0);
});

test('unknown op over the wire returns the unknown-op error', () => {
  const reply = ipc.roundTrip({ op: 'dance' });
  assert.match(reply.error, /unknown op dance/);
});
