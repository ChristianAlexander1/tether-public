'use strict';

// Live stdin channel: tty.stdin frames are written into a Readable installed
// as process.stdin. Empty frames are not EOF. A terminal stays open forever.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { setup, settle, until } = require('./helpers');
const workpath = require('../lib/workpath');

const session = setup({ ttyFds: [0, 1, 2], cols: 80, rows: 24 });

test('stdin: process.stdin is a TTY Readable with setRawMode', async () => {
  await session;
  assert.equal(process.stdin.isTTY, true);
  assert.equal(typeof process.stdin.setRawMode, 'function');
  assert.equal(process.stdin.isRaw, false);
  assert.equal(process.stdin.fd, 0);
});

test('stdin: pushed frames become readable data', async () => {
  const { server } = await session;
  const chunks = [];
  process.stdin.on('data', (c) => chunks.push(Buffer.from(c)));
  process.stdin.resume();
  server.stdin('hello');
  await until(() => chunks.length >= 1, { message: 'stdin data never arrived' });
  assert.equal(Buffer.concat(chunks).toString(), 'hello');
  process.stdin.pause();
  process.stdin.removeAllListeners('data');
});

test('stdin: empty push is not EOF; stream stays open', async () => {
  const { server } = await session;
  let ended = false;
  const onEnd = () => {
    ended = true;
  };
  process.stdin.on('end', onEnd);
  server.stdin(Buffer.alloc(0));
  server.push('tty.stdin', { dataB64: '' });
  await settle();
  assert.equal(ended, false, 'a terminal does not imply stdin EOF');
  process.stdin.off('end', onEnd);
});

test('stdin: two frames concatenate in order', async () => {
  const { server } = await session;
  const chunks = [];
  const onData = (c) => chunks.push(Buffer.from(c));
  process.stdin.on('data', onData);
  process.stdin.resume();
  server.stdin('ab');
  server.stdin('cd');
  await until(() => Buffer.concat(chunks).length >= 4, { message: 'expected abcd' });
  assert.equal(Buffer.concat(chunks).toString().endsWith('abcd') || Buffer.concat(chunks).toString().includes('abcd'), true);
  process.stdin.pause();
  process.stdin.off('data', onData);
});

test('workpath: /work rewrites onto TETHER_HOST_CWD', () => {
  const prev = process.env.TETHER_HOST_CWD;
  process.env.TETHER_HOST_CWD = '/tmp/host-workspace';
  try {
    assert.equal(workpath.mapWorkPath('/work'), '/tmp/host-workspace');
    assert.equal(workpath.mapWorkPath('/work/src/a.js'), '/tmp/host-workspace/src/a.js');
    assert.equal(workpath.mapWorkPath('/etc/passwd'), '/etc/passwd');
    assert.equal(workpath.mapWorkPath('relative'), 'relative');
  } finally {
    if (prev === undefined) delete process.env.TETHER_HOST_CWD;
    else process.env.TETHER_HOST_CWD = prev;
  }
});

test('workpath: attach rewrites writeFileSync of /work paths', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tether-work-'));
  const prev = process.env.TETHER_HOST_CWD;
  process.env.TETHER_HOST_CWD = dir;
  try {
    workpath.attach();
    fs.writeFileSync('/work/from-guest.txt', 'ok');
    const written = fs.readFileSync(path.join(dir, 'from-guest.txt'), 'utf8');
    assert.equal(written, 'ok');
  } finally {
    if (prev === undefined) delete process.env.TETHER_HOST_CWD;
    else process.env.TETHER_HOST_CWD = prev;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
