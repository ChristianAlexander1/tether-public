'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const os = require('../lib/os');
const tty = require('../lib/tty');
const ipc = require('../lib/ipc');
const { startServer, handleRequest } = require('./mock-backend');
const { withIpc } = require('./helper');

describe('os / tty', () => {
  it('18 os.platform forwards the native value', () => {
    assert.equal(os.platform(), process.platform);
  });

  it('os.type forwards the native value', () => {
    assert.equal(os.type(), require('node:os').type());
  });

  it('os.homedir is a non-empty path', () => {
    assert.ok(os.homedir().length > 0);
  });

  it('os.tmpdir is a non-empty path', () => {
    assert.ok(os.tmpdir().length > 0);
  });

  it('os.homedir respects the job HOME', () => {
    const prev = process.env.HOME;
    process.env.HOME = '/Users/shim-test';
    assert.equal(os.homedir(), '/Users/shim-test');
    if (prev == null) delete process.env.HOME;
    else process.env.HOME = prev;
  });

  it('os.tmpdir respects the job TMPDIR', () => {
    const prev = process.env.TMPDIR;
    process.env.TMPDIR = '/tmp/tether';
    assert.equal(os.tmpdir(), '/tmp/tether');
    if (prev == null) delete process.env.TMPDIR;
    else process.env.TMPDIR = prev;
  });

  it('17 tty.isatty true when TETHER_INTERACTIVE=1', () => {
    process.env.TETHER_INTERACTIVE = '1';
    try {
      assert.equal(tty.isatty(0), true);
      assert.equal(tty.isatty(1), true);
    } finally {
      delete process.env.TETHER_INTERACTIVE;
    }
  });

  it('tty.isatty false when not interactive', () => {
    delete process.env.TETHER_INTERACTIVE;
    assert.equal(tty.isatty(0), false);
  });

  it('tty.ReadStream setRawMode', () => {
    const s = new tty.ReadStream(0);
    s.setRawMode(true);
    assert.equal(s.isRaw, true);
  });

  it('tty.WriteStream window size', () => {
    const s = new tty.WriteStream(1);
    const [c, r] = s.getWindowSize();
    assert.ok(c > 0 && r > 0);
    assert.ok(s.hasColors(8));
    assert.equal(typeof s.getColorDepth(), 'number');
  });

  it('os.cpus length', () => {
    assert.ok(os.cpus().length >= 1);
  });

  it('os.arch forwards the native value', () => {
    assert.equal(os.arch(), process.arch);
  });

  it('os.userInfo has username and homedir', () => {
    const u = os.userInfo();
    assert.ok(u.username);
    assert.ok(u.homedir);
  });

  it('os.endianness forwards the native value', () => {
    assert.equal(os.endianness(), require('node:os').endianness());
  });

  it('os.EOL newline', () => {
    assert.equal(os.EOL, '\n');
  });

  it('os.networkInterfaces forwards native interfaces', () => {
    assert.deepEqual(os.networkInterfaces(), require('node:os').networkInterfaces());
  });

  it('os.constants.signals.SIGINT is 2', () => {
    assert.equal(os.constants.signals.SIGINT, 2);
  });

  it('os.availableParallelism matches cpus', () => {
    assert.equal(os.availableParallelism(), os.cpus().length);
  });

  it('os.getPriority is the native implementation', () => {
    assert.equal(os.getPriority(), require('node:os').getPriority());
  });

  it('os.totalmem and freemem positive', () => {
    assert.ok(os.totalmem() > 0);
    assert.ok(os.freemem() > 0);
  });

  it('os.uptime number', () => {
    assert.equal(typeof os.uptime(), 'number');
  });

  it('os.loadavg forwards native values', () => {
    const values = os.loadavg();
    assert.equal(values.length, 3);
    values.forEach(value => assert.equal(typeof value, 'number'));
  });

  it('os.hostname', () => {
    assert.ok(os.hostname().length > 0);
  });

  it('os.release and version', () => {
    assert.ok(os.release());
    assert.ok(os.version());
  });

  it('os.machine', () => {
    assert.ok(os.machine());
  });

  it('os.devNull', () => {
    assert.equal(os.devNull, '/dev/null');
  });
});

describe('ipc', () => {
  it('10 ipc unix socket round-trip', async () => {
    const backend = await startServer();
    process.env.TETHER_IPC_SOCK = backend.path;
    ipc.resetClient();
    try {
      const reply = await ipc.sendRequest({
        kind: 'spawn',
        file: 'echo',
        args: ['ping'],
        cwd: '/work',
        env: {},
        interactive: false,
      });
      assert.equal(reply.ok, true);
      assert.equal(reply.exitCode, 0);
      assert.match(reply.stdout, /ping/);
    } finally {
      ipc.resetClient();
      await backend.close();
      delete process.env.TETHER_IPC_SOCK;
    }
  });

  it('ipc cancel round-trip', async () => {
    await withIpc(async () => {
      const reply = await ipc.sendRequest({ kind: 'cancel' });
      assert.equal(reply.ok, true);
      assert.equal(reply.exitCode, 130);
    });
  });

  it('ipc missing config throws ENOIPC', () => {
    const prev = process.env.TETHER_IPC_SOCK;
    delete process.env.TETHER_IPC_SOCK;
    delete process.env.TETHER_IPC_FD;
    delete process.env.TETHER_IPC_REPLY_FD;
    ipc.resetClient();
    assert.throws(() => ipc.getClient(), (e) => e.code === 'ENOIPC');
    if (prev) process.env.TETHER_IPC_SOCK = prev;
  });

  it('handleRequest ENOENT', () => {
    const r = handleRequest({ kind: 'spawn', file: '/no/such/cmd', args: [] });
    assert.equal(r.code, 'ENOENT');
    assert.equal(r.ok, false);
  });

  it('sync socket helper round-trip', async () => {
    await withIpc(async () => {
      const reply = ipc.sendRequestSync({
        kind: 'spawn',
        file: 'git',
        args: ['status'],
        cwd: '/work',
        env: {},
        interactive: false,
      });
      assert.equal(reply.ok, true);
      assert.match(reply.stdout, /branch/);
    });
  });

  it('ipc FD pair writeSync/readSync', async () => {
    const fs = require('fs');
    const os = require('os');
    const path = require('path');
    const { spawn } = require('node:child_process');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tether-fd-'));
    const reqPath = path.join(dir, 'req');
    const repPath = path.join(dir, 'rep');
    fs.writeFileSync(reqPath, '');
    fs.writeFileSync(repPath, '');
    try {
      fs.unlinkSync(reqPath);
      fs.unlinkSync(repPath);
    } catch (_) {}
    require('node:child_process').execFileSync('mkfifo', [reqPath, repPath]);

    const host = spawn(process.execPath, [path.join(__dirname, 'fd-host.js'), reqPath, repPath], {
      stdio: 'ignore',
    });
    await new Promise((r) => setTimeout(r, 80));

    const wfd = fs.openSync(reqPath, fs.constants.O_RDWR);
    const rfd = fs.openSync(repPath, fs.constants.O_RDWR);
    delete process.env.TETHER_IPC_SOCK;
    process.env.TETHER_IPC_FD = String(wfd);
    process.env.TETHER_IPC_REPLY_FD = String(rfd);
    ipc.resetClient();
    try {
      const reply = ipc.sendRequestSync({
        kind: 'spawn',
        file: 'echo',
        args: ['fd'],
        cwd: '/',
        env: {},
        interactive: false,
      });
      assert.equal(reply.ok, true);
      assert.match(reply.stdout, /fd/);
    } finally {
      ipc.resetClient();
      delete process.env.TETHER_IPC_FD;
      delete process.env.TETHER_IPC_REPLY_FD;
      try {
        fs.closeSync(wfd);
        fs.closeSync(rfd);
      } catch (_) {}
      host.kill();
      try {
        fs.unlinkSync(reqPath);
        fs.unlinkSync(repPath);
        fs.rmdirSync(dir);
      } catch (_) {}
    }
  });
});
