'use strict';

// test/fake-spawn.js — a child_process-compatible { spawn, spawnSync }
// fake used by spawn tests. It supports a scripted per-command behavior.
//
// Usage:
//   const cp = makeFakeSpawn({
//     scripts: {
//       'echo': { stdout: Buffer.from('hi\n'), exitCode: 0 },
//       'fail': { exitCode: 2, stderr: Buffer.from('nope\n') },
//       'killed': { signal: 'SIGKILL' },
//     },
//     // Optional: commands that throw synchronously (ENOENT path).
//     throws: { 'missing': { code: 'ENOENT', message: 'spawn missing ENOENT' } },
//   });

const { EventEmitter } = require('node:events');
const { Readable, Writable } = require('node:stream');

function makeFakeSpawn(opts) {
  const scripts = (opts && opts.scripts) || {};
  const throws = (opts && opts.throws) || {};

  function makeStream(content) {
    if (content == null) return null;
    const s = new Readable({
      read() {
        if (!this._sent) {
          this.push(Buffer.isBuffer(content) ? content : Buffer.from(content));
          this._sent = true;
        } else {
          this.push(null);
        }
      },
    });
    return s;
  }

  function makeWritable() {
    return new Writable({ write(_c, _e, cb) { cb(); } });
  }

  function spawn(command, args, options) {
    if (throws[command]) {
      const e = new Error(throws[command].message || `spawn ${command} ENOENT`);
      e.code = throws[command].code || 'ENOENT';
      throw e;
    }
    const script = scripts[command] || { stdout: Buffer.alloc(0), exitCode: 0 };

    const stdio = options && options.stdio;
    const stdoutConfig = stdio ? stdio[1] : 'pipe';
    const stderrConfig = stdio ? stdio[2] : 'pipe';
    const stdinConfig = stdio ? stdio[0] : 'pipe';

    const child = new EventEmitter();
    child.pid = Math.floor(Math.random() * 100000) + 1000;
    child.stdout = stdoutConfig === 'pipe' ? makeStream(script.stdout) : null;
    child.stderr = stderrConfig === 'pipe' ? makeStream(script.stderr) : null;
    child.stdin = stdinConfig === 'pipe' ? makeWritable() : null;

    let killed = false;
    child.kill = function (signal) {
      if (killed) return false;
      killed = true;
      const sig = script.signal || signal || 'SIGTERM';
      process.nextTick(() => {
        child.emit('close', null, sig);
      });
      return true;
    };
    child.unref = function () {};
    child.ref = function () {};

    // Emit close on next tick for both normal and signal-terminated
    // scripts. A signal script can also be kill()ed (which just re-emits).
    process.nextTick(() => {
      if (killed) return; // kill() already settled it
      if (script.signal) {
        child.emit('close', null, script.signal);
      } else {
        child.emit('close', script.exitCode == null ? 0 : script.exitCode, null);
      }
    });

    return child;
  }

  function spawnSync(command, args, options) {
    if (throws[command]) {
      const e = new Error(throws[command].message || `spawnSync ${command} ENOENT`);
      e.code = throws[command].code || 'ENOENT';
      throw e;
    }
    const script = scripts[command] || {};
    return {
      pid: 1234,
      status: script.signal ? null : (script.exitCode == null ? 0 : script.exitCode),
      signal: script.signal || null,
      stdout: script.stdout ? (Buffer.isBuffer(script.stdout) ? script.stdout : Buffer.from(script.stdout)) : Buffer.alloc(0),
      stderr: script.stderr ? (Buffer.isBuffer(script.stderr) ? script.stderr : Buffer.from(script.stderr)) : Buffer.alloc(0),
    };
  }

  return { spawn, spawnSync };
}

module.exports = { makeFakeSpawn };
