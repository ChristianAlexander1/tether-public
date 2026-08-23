'use strict';
/**
 * Persistent Node service bootstrap for nodejs-mobile (single engine instance).
 * Swift posts JSON job lines on TERMX_JOB_FD; replies with exit code on TERMX_JOB_REPLY_FD.
 * Requires the delivered @termx/shim (lib/child_process.js uses TERMX_IPC_SOCKET per job).
 *
 * Two rules keep the app alive (docs/PROJECT-CONTEXT.md "hard-won rules"):
 *  - The engine shares the app's process. A real process.exit() (npm calls it
 *    on every run) would kill the whole app, so exit is trapped and turned
 *    into the job's exit code.
 *  - A script job is finished when the script says so — process.exit(), or
 *    the event loop draining ('beforeExit') — NOT when runMain() returns;
 *    npm and most CLIs do all their work asynchronously. For 'beforeExit' to
 *    fire, the job intake must not hold the loop open, so it polls a
 *    non-blocking fd on a timer that is unref'd while a script runs.
 */
require('./index.js');

const fs = require('fs');
const ipc = require('./lib/ipc');

const jobFD = Number(process.env.TERMX_JOB_FD ?? -1);
const jobReplyFD = Number(process.env.TERMX_JOB_REPLY_FD ?? -1);

function writeReply(obj) {
  fs.writeSync(jobReplyFD, JSON.stringify(obj) + '\n');
}

// ---- exit trapping (permanent) ------------------------------------------

class TermxExit extends Error {
  constructor(code) {
    super('termx-exit');
    this.termxExitCode = Number(code ?? process.exitCode ?? 0) | 0;
  }
}

process.reallyExit = function trappedReallyExit(code) {
  // Last line of defense: nothing in the embedded engine may kill the app.
  finishScript(Number(code ?? 0) | 0);
};
process.exit = function trappedExit(code) {
  throw new TermxExit(code);
};

// The active script job's completion callback (null when no script running).
let scriptFinish = null;

function finishScript(code) {
  if (scriptFinish) {
    const f = scriptFinish;
    scriptFinish = null;
    f(code);
  }
}

process.on('uncaughtException', (err) => {
  if (err instanceof TermxExit) {
    finishScript(err.termxExitCode);
    return;
  }
  const message = String(err && err.stack ? err.stack : err);
  try { process.stderr.write(message + '\n'); } catch (_) { /* ignore */ }
  finishScript(1);
});

process.on('unhandledRejection', (reason) => {
  if (reason instanceof TermxExit) {
    finishScript(reason.termxExitCode);
    return;
  }
  const message = String(reason && reason.stack ? reason.stack : reason);
  try { process.stderr.write('Unhandled rejection: ' + message + '\n'); } catch (_) { /* ignore */ }
  finishScript(1);
});

// ---- job runner -----------------------------------------------------------

async function runJob(job, onDone) {
  const prevCwd = process.cwd();
  let replied = false;
  const reply = (obj) => {
    if (replied) return;
    replied = true;
    try { process.chdir(prevCwd); } catch (_) { /* ignore */ }
    writeReply(obj);
    onDone();
  };

  try {
    if (job.cwd) process.chdir(job.cwd);
    if (job.env) {
      for (const [k, v] of Object.entries(job.env)) process.env[k] = v;
    }
    process.env.TERMX_INTERACTIVE = job.interactive ? '1' : '0';

    if (process.env.TERMX_IPC_SOCKET) {
      await ipc.connect();
    }

    if (job.kind === 'version') {
      process.stdout.write(process.version + '\n');
      reply({ exitCode: 0 });
      return;
    }

    if (job.kind === 'usageError') {
      process.stderr.write((job.message || 'node: bad usage') + '\n');
      reply({ exitCode: 9 });
      return;
    }

    if (job.kind === 'help') {
      process.stdout.write([
        'Usage: node [options] [script.js] [arguments]',
        '',
        '  -v, --version   print the Node.js version',
        '  -e, --eval    " script"   evaluate script',
        '  -p, --print   " script"   evaluate script and print the result',
        '  -h, --help      print this message',
        '',
        'Tether runs Node in-process, so not every upstream flag is supported.',
        ''
      ].join('\n'));
      reply({ exitCode: 0 });
      return;
    }

    if (job.kind === 'print' || job.kind === 'eval') {
      const source = job.source ?? '';
      // eslint-disable-next-line no-eval
      const value = eval(source);
      if (job.kind === 'print') {
        const text = typeof value === 'string' ? value : require('util').inspect(value);
        process.stdout.write(text + '\n');
      }
      reply({ exitCode: 0 });
      return;
    }

    if (job.kind === 'module') {
      require(job.module);
      reply({ exitCode: 0 });
      return;
    }

    // ---- script: run to *completion*, not just through runMain() ----------
    const argv = Array.isArray(job.argv) ? job.argv.slice() : [];
    process.argv = argv;
    process.exitCode = 0;

    scriptFinish = (code) => {
      process.removeListener('beforeExit', onBeforeExit);
      reply({ exitCode: Number(code ?? 0) | 0 });
    };
    const onBeforeExit = () => finishScript(process.exitCode ?? 0);
    process.on('beforeExit', onBeforeExit);

    require('module').runMain();
    // No reply here: the script finishes via process.exit (trapped), an
    // uncaught error, or the event loop draining (beforeExit).
  } catch (err) {
    if (err instanceof TermxExit) {
      scriptFinish = null;
      reply({ exitCode: err.termxExitCode });
      return;
    }
    scriptFinish = null;
    const message = String(err && err.stack ? err.stack : err);
    try { process.stderr.write(message + '\n'); } catch (_) { /* ignore */ }
    reply({ exitCode: 1, error: message });
  }
}

// ---- job intake -----------------------------------------------------------
// The job fd is wrapped in a real libuv handle (net.Socket works for pipes —
// the same wrapping Node uses for piped stdin), so it can be ref'd while idle
// (keeping the engine alive between jobs) and unref'd while a script runs so
// the script's own handles decide when 'beforeExit' fires.

if (jobFD >= 0 && jobReplyFD >= 0) {
  const net = require('net');
  const intake = new net.Socket({ fd: jobFD, readable: true, writable: false });

  let partial = '';
  let running = false;
  const queue = [];

  function startNext() {
    if (running || queue.length === 0) return;
    running = true;
    intake.unref();
    const job = queue.shift();
    runJob(job, () => {
      running = false;
      intake.ref();
      startNext();
    }).catch((jobErr) => {
      running = false;
      intake.ref();
      writeReply({ exitCode: 1, error: String(jobErr) });
      startNext();
    });
  }

  intake.on('data', (chunk) => {
    partial += chunk.toString('utf8');
    let idx;
    while ((idx = partial.indexOf('\n')) >= 0) {
      const line = partial.slice(0, idx).trim();
      partial = partial.slice(idx + 1);
      if (line) {
        try {
          queue.push(JSON.parse(line));
        } catch (e) {
          writeReply({ exitCode: 1, error: 'bad job line: ' + String(e) });
        }
      }
    }
    startNext();
  });
  intake.on('error', (e) => {
    writeReply({ exitCode: 1, error: 'job intake error: ' + String(e) });
  });

  writeReply({ ready: true });
}
