'use strict';

const test = require('node:test');
const assert = require('node:assert');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { spawn } = require('node:child_process');

const { FrameParser, encodeFrame } = require('../lib/ipc/framing');

/**
 * Regression: the shim's own IPC transport must not keep the host program's
 * event loop alive.
 *
 * A libuv socket is ref'd by default. With the connection ref'd the loop is
 * never empty, so `process.on('beforeExit')` never fires. Tether's embedded
 * runtime uses exactly that event to decide a script-file job has finished, so
 * a ref'd transport made every such command hang the terminal forever:
 * `cowsay hi` printed its cow and then wedged the shell, with no way back to a
 * prompt. `node -e` was unaffected because that job kind replies directly,
 * which is why it stayed hidden.
 *
 * The rest of the suite runs over in-memory duplexes, which hold no libuv
 * handle and therefore cannot observe this at all. This test uses a real Unix
 * socket and a real child process on purpose.
 */
test('the shim transport does not keep the host program alive', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tether-shim-liveness-'));
  const sockPath = path.join(dir, 'ipc.sock');

  // Minimal TJIP/2 responder: answer the handshake, ignore everything else.
  const server = net.createServer((conn) => {
    const parser = new FrameParser((env) => {
      if (env.kind === 'req' && env.type === 'hello') {
        conn.write(encodeFrame({
          v: 2, kind: 'res', id: env.id, type: 'hello',
          body: {
            ok: true, proto: 2, ttyFds: [0, 1, 2], cols: 80, rows: 24,
            termName: 'xterm-256color', colorTerm: 'truecolor',
            features: ['tty', 'spawn', 'flow'],
          },
        }));
      }
    });
    conn.on('data', (chunk) => { try { parser.consume(chunk); } catch (_) {} });
    conn.on('error', () => {});
  });
  await new Promise((resolve) => server.listen(sockPath, resolve));

  try {
    const shimPath = require.resolve('../lib/index.js');
    const script = `
      const shim = require(${JSON.stringify(shimPath)});
      process.on('beforeExit', () => { process.stdout.write('BEFORE_EXIT\\n'); });
      shim.ready().catch(() => {});
    `;
    const child = spawn(process.execPath, ['-e', script], {
      env: { ...process.env, TETHER_IPC_SOCK: sockPath },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    child.stdout.on('data', (d) => { stdout += d; });

    const outcome = await new Promise((resolve) => {
      const timer = setTimeout(() => { child.kill('SIGKILL'); resolve('timeout'); }, 8000);
      child.on('exit', (code) => { clearTimeout(timer); resolve(code); });
    });

    assert.notStrictEqual(
      outcome, 'timeout',
      "the shim's socket held the event loop open; the transport is not unref'd"
    );
    assert.match(
      stdout, /BEFORE_EXIT/,
      'beforeExit must fire once the program itself has no work left'
    );
  } finally {
    server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
