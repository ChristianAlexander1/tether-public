'use strict';
/**
 * Persistent Node service bootstrap for nodejs-mobile (single engine instance).
 * Swift posts JSON job lines on TERMX_JOB_FD; replies with exit code on TERMX_JOB_REPLY_FD.
 * Requires the delivered @termx/shim (lib/child_process.js uses TERMX_IPC_SOCKET per job).
 */
require('./index.js');

const fs = require('fs');
const ipc = require('./lib/ipc');

const jobFD = Number(process.env.TERMX_JOB_FD ?? -1);
const jobReplyFD = Number(process.env.TERMX_JOB_REPLY_FD ?? -1);

function writeReply(obj) {
  fs.writeSync(jobReplyFD, JSON.stringify(obj) + '\n');
}

async function runJob(job) {
  const prevCwd = process.cwd();
  try {
    if (job.cwd) process.chdir(job.cwd);
    if (job.env) {
      for (const [k, v] of Object.entries(job.env)) process.env[k] = v;
    }
    process.env.TERMX_INTERACTIVE = job.interactive ? '1' : '0';

    if (process.env.TERMX_IPC_SOCKET) {
      await ipc.connect();
    }

    if (job.kind === 'eval') {
      const source = job.source ?? '';
      // eslint-disable-next-line no-eval
      eval(source);
      writeReply({ exitCode: 0 });
      return;
    }

    if (job.kind === 'module') {
      require(job.module);
      writeReply({ exitCode: 0 });
      return;
    }

    const argv = Array.isArray(job.argv) ? job.argv.slice() : [];
    process.argv = argv;

    if (argv.length >= 3 && argv[1] === '-e') {
      // eslint-disable-next-line no-eval
      eval(argv[2]);
      writeReply({ exitCode: 0 });
      return;
    }

    require('module').runMain();
    writeReply({ exitCode: 0 });
  } catch (err) {
    const message = String(err && err.stack ? err.stack : err);
    try { process.stderr.write(message + '\n'); } catch (_) { /* ignore */ }
    writeReply({ exitCode: 1, error: message });
  } finally {
    try { process.chdir(prevCwd); } catch (_) { /* ignore */ }
  }
}

if (jobFD >= 0 && jobReplyFD >= 0) {
  writeReply({ ready: true });
  const buf = Buffer.alloc(1 << 20);
  let partial = '';
  // TERMX_JOB_FD is an already-open OS descriptor from Swift — do not fs.open() it
  // (Node's fs.open expects a path string).
  (function readLoop() {
    fs.read(jobFD, buf, 0, buf.length, null, (readErr, n) => {
      if (readErr) {
        writeReply({ exitCode: 1, error: String(readErr) });
        return;
      }
      if (n === 0) return;
      partial += buf.slice(0, n).toString('utf8');
      let idx;
      while ((idx = partial.indexOf('\n')) >= 0) {
        const line = partial.slice(0, idx).trim();
        partial = partial.slice(idx + 1);
        if (line) {
          runJob(JSON.parse(line)).catch((jobErr) => {
            writeReply({ exitCode: 1, error: String(jobErr) });
          });
        }
      }
      readLoop();
    });
  })();
}
