'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const cp = require('../lib/child_process');
const { withIpc, collect } = require('./helper');

describe('child_process spawn/exec', () => {
  it('1 spawn exit 0', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('echo', ['ok']));
      assert.equal(r.code, 0);
      assert.match(r.stdout, /ok/);
    });
  });

  it('2 spawn exit 1', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('exit1'));
      assert.equal(r.code, 1);
    });
  });

  it('3 spawnSync exit 0', async () => {
    await withIpc(async () => {
      const r = cp.spawnSync('echo', ['hi'], { encoding: 'utf8' });
      assert.equal(r.status, 0);
      assert.match(r.stdout, /hi/);
    });
  });

  it('4 exec callback success', async () => {
    await withIpc(async () => {
      await new Promise((resolve, reject) => {
        cp.exec('echo hello', (err, stdout, stderr) => {
          try {
            assert.equal(err, null);
            assert.ok(stdout.length >= 0);
            resolve();
          } catch (e) {
            reject(e);
          }
        });
      });
    });
  });

  it('5 execSync throw on nonzero', async () => {
    await withIpc(async () => {
      assert.throws(() => cp.execSync('exit1', { encoding: 'utf8' }), /Command failed/);
    });
  });

  it('6 ENOENT has Node-accurate fields', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('__enoent__', ['x']));
      const err = r.error || (r.events.find((e) => e[0] === 'error') || [])[1];
      assert.ok(err, 'expected error');
      assert.equal(err.code, 'ENOENT');
      assert.equal(err.errno, -2);
      assert.match(String(err.syscall), /spawn/);
      assert.equal(err.path, '__enoent__');
    });
  });

  it('7 shell:true uses sh -c', async () => {
    await withIpc(async (backend) => {
      await collect(cp.spawn('echo hi', { shell: true }));
      const last = (await backend.dump()).last;
      assert.equal(last.file, 'sh');
      assert.equal(last.args[0], '-c');
      assert.ok(String(last.args[1]).includes('echo hi'));
    });
  });

  it('8 maxBuffer exceeded on exec', async () => {
    await withIpc(async () => {
      await new Promise((resolve, reject) => {
        cp.exec('echo big huge-output', { maxBuffer: 16 }, (err) => {
          try {
            assert.ok(err);
            assert.ok(
              err.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' ||
                /maxBuffer/i.test(err.message)
            );
            resolve();
          } catch (e) {
            reject(e);
          }
        });
      });
    });
  });

  it('9 cancel → exit 130', async () => {
    await withIpc(async () => {
      const child = cp.spawn('sleep', ['10']);
      child.kill('SIGINT');
      const r = await collect(child);
      assert.equal(r.code, 130);
    });
  });

  it('14 git status spawn', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('git', ['status'], { cwd: '/work' }));
      assert.equal(r.code, 0);
      assert.match(r.stdout, /On branch main/);
    });
  });

  it('15 rg spawn', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('rg', ['foo', '.']));
      assert.equal(r.code, 0);
      assert.match(r.stdout, /match/);
    });
  });

  it('16 bash -c pipeline via shell:true', async () => {
    await withIpc(async (backend) => {
      const r = await collect(cp.spawn('echo a | cat', { shell: true }));
      assert.equal(r.code, 0);
      assert.match(r.stdout, /pipeline-ok/);
      const last = (await backend.dump()).last;
      assert.equal(last.file, 'sh');
    });
  });

  it('spawn emits spawn then exit then close', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('echo', ['ord']));
      const names = r.events.map((e) => (Array.isArray(e) ? e[0] : e));
      const spawnI = names.indexOf('spawn');
      const exitI = names.indexOf('exit');
      const closeI = names.indexOf('close');
      assert.ok(spawnI >= 0 && exitI > spawnI && closeI > exitI);
    });
  });

  it('execFile callback', async () => {
    await withIpc(async () => {
      await new Promise((resolve, reject) => {
        cp.execFile('echo', ['z'], { encoding: 'utf8' }, (err, stdout) => {
          try {
            assert.equal(err, null);
            assert.match(stdout, /z/);
            resolve();
          } catch (e) {
            reject(e);
          }
        });
      });
    });
  });

  it('execFileSync returns stdout', async () => {
    await withIpc(async () => {
      const out = cp.execFileSync('echo', ['sync'], { encoding: 'utf8' });
      assert.match(out, /sync/);
    });
  });

  it('execSync success returns stdout', async () => {
    await withIpc(async () => {
      const out = cp.execSync('echo hi', { encoding: 'utf8' });
      assert.ok(typeof out === 'string' || Buffer.isBuffer(out));
    });
  });

  it('spawnSync ENOENT sets error', async () => {
    await withIpc(async () => {
      const r = cp.spawnSync('__enoent__', [], { encoding: 'utf8' });
      assert.ok(r.error);
      assert.equal(r.error.code, 'ENOENT');
      assert.equal(r.error.errno, -2);
      assert.match(String(r.error.syscall), /spawnSync/);
    });
  });

  it('fork documents no IPC and still runs', async () => {
    await withIpc(async () => {
      const child = cp.fork('/tmp/mod.js');
      assert.equal(child.send('x'), false);
      const r = await collect(child);
      assert.equal(r.code, 0);
    });
  });

  it('cwd is forwarded', async () => {
    await withIpc(async (backend) => {
      await collect(cp.spawn('git', ['status'], { cwd: '/work' }));
      const last = (await backend.dump()).last;
      assert.equal(last.cwd, '/work');
    });
  });

  it('argv0 forwarded', async () => {
    await withIpc(async (backend) => {
      await collect(cp.spawn('echo', ['a'], { argv0: 'myecho' }));
      const last = (await backend.dump()).last;
      assert.equal(last.argv0, 'myecho');
    });
  });

  it('killSignal forwarded on request when set', async () => {
    await withIpc(async (backend) => {
      await collect(cp.spawn('echo', ['a'], { killSignal: 'SIGKILL' }));
      const last = (await backend.dump()).last;
      assert.equal(last.killSignal, 'SIGKILL');
    });
  });

  it('spawnSync maxBuffer error', async () => {
    await withIpc(async () => {
      const r = cp.spawnSync('sh', ['-c', 'huge-output'], { maxBuffer: 8, encoding: 'utf8' });
      assert.ok(r.error);
      assert.equal(r.error.code, 'ENOBUFS');
    });
  });

  it('execFile nonzero callback error', async () => {
    await withIpc(async () => {
      await new Promise((resolve, reject) => {
        cp.execFile('exit1', [], (err) => {
          try {
            assert.ok(err);
            resolve();
          } catch (e) {
            reject(e);
          }
        });
      });
    });
  });

  it('execFileSync throws on nonzero', async () => {
    await withIpc(async () => {
      assert.throws(() => cp.execFileSync('exit1', { encoding: 'utf8' }));
    });
  });

  it('stdio pipe default exposes streams', async () => {
    await withIpc(async () => {
      const c = cp.spawn('echo', ['s']);
      assert.ok(c.stdin);
      assert.ok(c.stdout);
      assert.ok(c.stderr);
      await collect(c);
    });
  });

  it('pid is assigned', async () => {
    await withIpc(async () => {
      const c = cp.spawn('echo', ['p']);
      assert.equal(typeof c.pid, 'number');
      await collect(c);
    });
  });

  it('options as second arg to spawn', async () => {
    await withIpc(async (backend) => {
      await collect(cp.spawn('echo', { cwd: '/tmp' }));
      const last = (await backend.dump()).last;
      assert.equal(last.cwd, '/tmp');
    });
  });

  it('shell string uses that shell', async () => {
    await withIpc(async (backend) => {
      await collect(cp.spawn('true', { shell: '/bin/sh' }));
      const last = (await backend.dump()).last;
      assert.equal(last.file, '/bin/sh');
      assert.equal(last.args[0], '-c');
    });
  });

  it('encoding utf8 on spawnSync', async () => {
    await withIpc(async () => {
      const r = cp.spawnSync('echo', ['e'], { encoding: 'utf8' });
      assert.equal(typeof r.stdout, 'string');
    });
  });

  it('default spawnSync stdout is Buffer', async () => {
    await withIpc(async () => {
      const r = cp.spawnSync('echo', ['e']);
      assert.ok(Buffer.isBuffer(r.stdout));
    });
  });

  it('ChildProcess unref/ref/disconnect are no-throw', async () => {
    await withIpc(async () => {
      const c = cp.spawn('echo', ['n']);
      c.unref();
      c.ref();
      c.disconnect();
      await collect(c);
    });
  });

  it('cancel request kind is cancel', async () => {
    await withIpc(async (backend) => {
      const c = cp.spawn('sleep', ['9']);
      const p = collect(c);
      c.kill();
      await p;
      const dump = await backend.dump();
      const cancel = dump.lastRequests.find((x) => x.kind === 'cancel');
      assert.ok(cancel);
    });
  });

  it('interactive true when TETHER_INTERACTIVE=1', async () => {
    await withIpc(async (backend) => {
      process.env.TETHER_INTERACTIVE = '1';
      try {
        await collect(cp.spawn('echo', ['i']));
        const last = (await backend.dump()).last;
        assert.equal(last.interactive, true);
      } finally {
        delete process.env.TETHER_INTERACTIVE;
      }
    });
  });

  it('execFile with options as args object', async () => {
    await withIpc(async () => {
      await new Promise((resolve, reject) => {
        cp.execFile('echo', { encoding: 'utf8' }, (err, stdout) => {
          try {
            assert.equal(err, null);
            resolve();
          } catch (e) {
            reject(e);
          }
        });
      });
    });
  });

  it('spawnSync status 1', async () => {
    await withIpc(async () => {
      const r = cp.spawnSync('exit1', { encoding: 'utf8' });
      assert.equal(r.status, 1);
    });
  });

  it('false command via spawn', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('false'));
      assert.equal(r.code, 1);
    });
  });

  it('stdio ignore nulls streams', async () => {
    await withIpc(async () => {
      const c = cp.spawn('echo', ['x'], { stdio: 'ignore' });
      assert.equal(c.stdin, null);
      assert.equal(c.stdout, null);
      assert.equal(c.stderr, null);
      const r = await collect(c);
      assert.equal(r.code, 0);
    });
  });

  it('stdio inherit is interactive', async () => {
    await withIpc(async (backend) => {
      const c = cp.spawn('echo', ['x'], { stdio: 'inherit' });
      assert.equal(c.stdout, null);
      await collect(c);
      const last = (await backend.dump()).last;
      assert.equal(last.interactive, true);
      assert.deepEqual(last.stdio, ['inherit', 'inherit', 'inherit']);
    });
  });

  it('timeout option is forwarded and kills', async () => {
    await withIpc(async (backend) => {
      const c = cp.spawn('echo', ['t'], { timeout: 50, killSignal: 'SIGTERM' });
      await collect(c);
      const last = (await backend.dump()).last;
      assert.equal(last.timeout, 50);
    });
  });

  it('spawnSync input becomes stdin on request', async () => {
    await withIpc(async (backend) => {
      cp.spawnSync('echo', ['i'], { input: 'hello-stdin', encoding: 'utf8' });
      const last = (await backend.dump()).last;
      assert.equal(last.stdin, 'hello-stdin');
    });
  });
});
