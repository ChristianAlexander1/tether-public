'use strict';

/**
 * Mock Tether host IPC backend.
 * Speaks newline-delimited JSON on a unix domain socket.
 */

const net = require('net');
const fs = require('fs');
const path = require('path');
const os = require('os');

const BROWSER_CMDS = new Set(['open', 'xdg-open', 'sensible-browser', 'wslview']);

function handleRequest(req) {
  if (!req || typeof req !== 'object') {
    return { ok: false, exitCode: 1, stdout: '', stderr: 'bad request', pid: 1 };
  }

  if (req.kind === 'cancel') {
    return { ok: true, exitCode: 130, stdout: '', stderr: '', pid: req.pid || 1 };
  }

  if (req.kind !== 'spawn') {
    return { ok: false, exitCode: 1, stdout: '', stderr: 'unknown kind', pid: 1 };
  }

  const file = req.file;
  const args = req.args || [];
  const env = req.env || {};

  if (file === '__enoent__' || file === '/no/such/cmd' || file === 'definitely-not-installed') {
    return { ok: false, code: 'ENOENT', exitCode: null, stdout: '', stderr: '', pid: 0 };
  }

  if (BROWSER_CMDS.has(file)) {
    const url = args[0] || '';
    return {
      ok: true,
      exitCode: 0,
      stdout: `opened ${url}\n`,
      stderr: '',
      pid: 4242,
      echoEnv: {
        DISPLAY: env.DISPLAY,
        BROWSER: env.BROWSER,
        WAYLAND_DISPLAY: env.WAYLAND_DISPLAY,
      },
    };
  }

  if (file === 'git') {
    if (args[0] === 'status') {
      return { ok: true, exitCode: 0, stdout: 'On branch main\nnothing to commit\n', stderr: '', pid: 1001 };
    }
    return { ok: true, exitCode: 0, stdout: `git ${args.join(' ')}\n`, stderr: '', pid: 1001 };
  }

  if (file === 'rg') {
    return { ok: true, exitCode: 0, stdout: 'match: lib/child_process.js\n', stderr: '', pid: 1002 };
  }

  if (file === 'false' || (file === 'sh' && args.includes('exit 1'))) {
    return { ok: true, exitCode: 1, stdout: '', stderr: 'failed\n', pid: 1003 };
  }

  if (file === 'exit1') {
    return { ok: true, exitCode: 1, stdout: '', stderr: 'exit 1\n', pid: 1003 };
  }

  // shell:true → sh -c "<cmd>"
  if (file === 'sh' && args[0] === '-c') {
    const cmd = args[1] || '';
    if (cmd.includes('exit 1') || /\bexit1\b/.test(cmd) || cmd.trim() === 'exit1') {
      return { ok: true, exitCode: 1, stdout: '', stderr: 'failed\n', pid: 2001 };
    }
    if (cmd.includes('echo big') || cmd.includes('huge-output')) {
      return { ok: true, exitCode: 0, stdout: 'x'.repeat(10000), stderr: '', pid: 2002 };
    }
    if (cmd.includes('|')) {
      return { ok: true, exitCode: 0, stdout: 'pipeline-ok\n', stderr: '', pid: 2003 };
    }
    return { ok: true, exitCode: 0, stdout: `sh-c:${cmd}\n`, stderr: '', pid: 2000 };
  }

  if (file === 'echo') {
    return { ok: true, exitCode: 0, stdout: args.join(' ') + '\n', stderr: '', pid: 3000 };
  }

  if (file === 'node' || file.endsWith('/node')) {
    return { ok: true, exitCode: 0, stdout: 'fork-ok\n', stderr: '', pid: 3001 };
  }

  if (file === 'sleep') {
    return { ok: true, exitCode: 0, stdout: '', stderr: '', pid: 3002 };
  }

  return {
    ok: true,
    exitCode: 0,
    stdout: `${file} ${args.join(' ')}\n`.trim() + '\n',
    stderr: '',
    pid: 9999,
  };
}

function startServer(sockPath) {
  if (!sockPath) {
    sockPath = path.join(os.tmpdir(), `tether-ipc-${process.pid}-${Date.now()}.sock`);
  }
  try {
    fs.unlinkSync(sockPath);
  } catch (_) {}

  const lastRequests = [];
  const server = net.createServer((socket) => {
    let buf = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (!line.trim()) continue;
        let req;
        try {
          req = JSON.parse(line);
        } catch (e) {
          socket.write(JSON.stringify({ ok: false, stderr: String(e), exitCode: 1, stdout: '', pid: 0 }) + '\n');
          continue;
        }
        lastRequests.push(req);
        if (req.kind === '__dump') {
          socket.write(
            JSON.stringify({
              ok: true,
              lastRequests,
              last: lastRequests.filter((x) => x.kind === 'spawn').slice(-1)[0] || null,
            }) + '\n'
          );
          continue;
        }
        const reply = handleRequest(req);
        socket.write(JSON.stringify(reply) + '\n');
      }
    });
  });

  return new Promise((resolve, reject) => {
    server.on('error', reject);
    server.listen(sockPath, () => {
      resolve({
        path: sockPath,
        server,
        lastRequests,
        handleRequest,
        close() {
          return new Promise((res) => {
            server.close(() => {
              try {
                fs.unlinkSync(sockPath);
              } catch (_) {}
              res();
            });
          });
        },
      });
    });
  });
}

module.exports = { startServer, handleRequest, BROWSER_CMDS };
