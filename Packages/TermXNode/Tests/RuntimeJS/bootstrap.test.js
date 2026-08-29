'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');
const test = require('node:test');

const shimRoot = path.resolve(__dirname, '../../Sources/TermXNode/Resources/shim');
const bootstrap = path.join(shimRoot, 'bootstrap.js');

test('persistent bootstrap completes a job and stays ready for the next one', async (t) => {
  const env = { ...process.env, TETHER_JOB_FD: '3', TETHER_JOB_REPLY_FD: '4' };
  delete env.TETHER_IPC_SOCK;
  delete env.TERMX_IPC_SOCKET;

  const child = spawn(process.execPath, [bootstrap], {
    cwd: shimRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'],
  });
  t.after(() => {
    if (child.exitCode === null) child.kill('SIGKILL');
  });

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  const replies = [];
  let partial = '';
  const completed = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(
      `bootstrap timed out; stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
    )), 3000);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (!replies.some((reply) => reply.exitCode === 0)) {
        reject(new Error(`bootstrap exited early (code=${code}, signal=${signal}); stderr=${stderr}`));
      }
    });
    child.stdio[4].on('data', (chunk) => {
      partial += chunk.toString('utf8');
      let newline;
      while ((newline = partial.indexOf('\n')) >= 0) {
        const line = partial.slice(0, newline);
        partial = partial.slice(newline + 1);
        if (!line) continue;
        const reply = JSON.parse(line);
        replies.push(reply);
        if (reply.ready === true) {
          child.stdio[3].write(`${JSON.stringify({ kind: 'version' })}\n`);
        } else if (reply.exitCode === 0) {
          clearTimeout(timer);
          resolve();
        }
      }
    });
  });

  await completed;
  assert.match(stdout, /^v\d+/m);
  assert.equal(stderr, '');
  assert.deepEqual(replies, [{ ready: true }, { exitCode: 0 }]);
});
