'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const net = require('net');
const { spawn } = require('node:child_process');
const ipc = require('../lib/ipc');

/**
 * Host the mock IPC server in a *separate* process so spawnSync/readSync
 * can complete while the server still has an event loop.
 */
function startBackendProcess() {
  const sockPath = path.join(os.tmpdir(), `tether-ipc-${process.pid}-${Date.now()}.sock`);
  try {
    fs.unlinkSync(sockPath);
  } catch (_) {}
  const child = spawn(process.execPath, [path.join(__dirname, 'ipc-server-cli.js'), sockPath], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const lastRequests = [];
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('backend start timeout')), 5000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d) => {
      if (String(d).includes('ready')) {
        clearTimeout(t);
        resolve({
          path: sockPath,
          child,
          lastRequests,
          async peekRequests() {
            // fetch last requests via a control message is overkill;
            // connect and use a special kind? we store by wrapping — instead
            // re-read by sending nothing. Tests that inspect lastRequests
            // will use inspect() below.
          },
          async dump() {
            return inspectLast(sockPath);
          },
          get lastRequests() {
            throw new Error('use await backend.dump()');
          },
          close() {
            return new Promise((res) => {
              child.kill('SIGTERM');
              child.on('exit', () => {
                try {
                  fs.unlinkSync(sockPath);
                } catch (_) {}
                res();
              });
              setTimeout(res, 500);
            });
          },
        });
      }
    });
    child.on('error', reject);
    child.stderr.on('data', () => {});
  });
}

function inspectLast(sockPath) {
  // The child server doesn't expose lastRequests. Patch: send a dump request.
  return new Promise((resolve, reject) => {
    const s = net.connect({ path: sockPath });
    let buf = '';
    s.setEncoding('utf8');
    s.on('connect', () => s.write(JSON.stringify({ kind: '__dump' }) + '\n'));
    s.on('data', (c) => {
      buf += c;
      const i = buf.indexOf('\n');
      if (i !== -1) {
        s.end();
        try {
          resolve(JSON.parse(buf.slice(0, i)));
        } catch (e) {
          reject(e);
        }
      }
    });
    s.on('error', reject);
  });
}

async function withIpc(fn) {
  const backend = await startBackendProcess();
  process.env.TETHER_IPC_SOCK = backend.path;
  delete process.env.TETHER_IPC_FD;
  delete process.env.TETHER_IPC_REPLY_FD;
  ipc.resetClient();
  try {
    return await fn(backend);
  } finally {
    ipc.resetClient();
    await backend.close();
    delete process.env.TETHER_IPC_SOCK;
  }
}

function collect(child) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const events = [];
    child.on('spawn', () => events.push('spawn'));
    child.on('exit', (code, signal) => events.push(['exit', code, signal]));
    child.on('close', (code, signal) => {
      events.push(['close', code, signal]);
      resolve({ stdout, stderr, events, code, signal, child });
    });
    child.on('error', (err) => {
      events.push(['error', err]);
      // still wait for close if it comes
      setTimeout(() => resolve({ stdout, stderr, events, error: err, child }), 20);
    });
    if (child.stdout) {
      child.stdout.on('data', (d) => {
        stdout += d;
      });
    }
    if (child.stderr) {
      child.stderr.on('data', (d) => {
        stderr += d;
      });
    }
  });
}

module.exports = { withIpc, collect };
