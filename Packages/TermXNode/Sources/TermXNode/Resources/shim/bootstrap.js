'use strict';
/**
 * Persistent Node service bootstrap for nodejs-mobile (single engine instance).
 * Swift posts JSON job lines on TETHER_JOB_FD; replies on TETHER_JOB_REPLY_FD.
 *
 * Job boundaries are enforced by lib/job_lifecycle.js — each command gets clean stdin
 * and mandatory teardown so npm leftovers cannot leak into the next job.
 */
require('./index.js');

(function reassertProcessTitle() {
  let title = 'node';
  try { title = String(process.title || 'node'); } catch (_) { /* ignore */ }
  try { delete process.title; } catch (_) { /* ignore */ }
  try {
    Object.defineProperty(process, 'title', {
      configurable: true,
      enumerable: true,
      get() { return title; },
      set(value) { title = String(value); },
    });
  } catch (_) { /* ignore */ }
})();

const fs = require('fs');
const ipc = require('./lib/ipc');
const lifecycle = require('./lib/job_lifecycle');

const jobFD = Number(process.env.TETHER_JOB_FD ?? process.env.TERMX_JOB_FD ?? -1);
const jobReplyFD = Number(process.env.TETHER_JOB_REPLY_FD ?? process.env.TERMX_JOB_REPLY_FD ?? -1);

function writeReply(obj) {
  fs.writeSync(jobReplyFD, JSON.stringify(obj) + '\n');
}

class TermxExit extends Error {
  constructor(code) {
    super('termx-exit');
    this.termxExitCode = Number(code ?? process.exitCode ?? 0) | 0;
  }
}

process.reallyExit = function trappedReallyExit(code) {
  finishScript(Number(code ?? 0) | 0);
};
process.exit = function trappedExit(code) {
  throw new TermxExit(code);
};

let scriptFinish = null;
/** Set after intake socket is created — passed to lifecycle teardown. */
let intakeSocket = null;
/** Abort hook for the currently running job (cancel from Swift). */
let abortRunningJob = null;

function finishScript(code) {
  if (!scriptFinish) return;
  const f = scriptFinish;
  scriptFinish = null;
  lifecycle.silenceEventLoopStorm();
  try { ipc.clearTransport(); } catch (_) { /* ignore */ }
  f(code);
}

process.on('uncaughtException', (err) => {
  if (err instanceof TermxExit) {
    finishScript(err.termxExitCode);
    return;
  }
  const message = sanitizeHostPaths(String(err && err.stack ? err.stack : err));
  try { process.stderr.write(message + '\n'); } catch (_) { /* ignore */ }
  finishScript(1);
});

process.on('unhandledRejection', (reason) => {
  if (reason instanceof TermxExit) {
    finishScript(reason.termxExitCode);
    return;
  }
  const message = sanitizeHostPaths(String(reason && reason.stack ? reason.stack : reason));
  try { process.stderr.write('Unhandled rejection: ' + message + '\n'); } catch (_) { /* ignore */ }
  finishScript(1);
});

function sanitizeHostPaths(text) {
  return String(text)
    .replace(/\/Users\/[^/\s:'"]+/g, '/Users/<host>');
}

async function runJob(job, onDone) {
  const prevCwd = process.cwd();
  let replied = false;
  const reply = (obj) => {
    if (replied) return;
    replied = true;
    // Reply BEFORE teardown — finishJob closes leftover handles and can
    // destroy the job-reply pipe FD, which left Claude/npm failures hanging
    // the host forever (no exit code → shell stuck).
    try { process.chdir(prevCwd); } catch (_) { /* ignore */ }
    writeReply(obj);
    try { lifecycle.finishJob(intakeSocket, ipc); } catch (_) { /* ignore */ }
    onDone();
  };

  abortRunningJob = () => {
    if (replied) return;
    if (scriptFinish) {
      finishScript(130);
    } else {
      reply({ exitCode: 130 });
    }
  };

  try {
    if (job.cwd) process.chdir(job.cwd);
    if (job.env) {
      for (const [k, v] of Object.entries(job.env)) process.env[k] = v;
    }
    process.env.TETHER_INTERACTIVE = job.interactive ? '1' : '0';
    process.env.TERMX_INTERACTIVE = job.interactive ? '1' : '0';

    lifecycle.bindStdinFromJob(job);
    if (job.interactive) {
      lifecycle.enableLiveOutput();
    }

    if (process.env.TETHER_IPC_SOCK || process.env.TERMX_IPC_SOCKET) {
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
      const path = require('path');
      const Module = require('module');
      const evalFilename = path.join(process.cwd(), '[eval]');
      const evalModule = new Module(evalFilename);
      evalModule.filename = evalFilename;
      evalModule.paths = Module._nodeModulePaths(process.cwd());
      const requireFromCwd = evalModule.require.bind(evalModule);

      process.exitCode = 0;
      scriptFinish = (code) => {
        process.removeListener('beforeExit', onBeforeExit);
        reply({ exitCode: Number(code ?? 0) | 0 });
      };
      const onBeforeExit = () => finishScript(process.exitCode ?? 0);
      process.on('beforeExit', onBeforeExit);

      // eslint-disable-next-line no-eval
      const value = (function (require) { return eval(source); })(requireFromCwd);
      if (job.kind === 'print' && value !== undefined) {
        const text = typeof value === 'string' ? value : require('util').inspect(value);
        process.stdout.write(text + '\n');
      }
      return;
    }

    if (job.kind === 'module') {
      require(job.module);
      reply({ exitCode: 0 });
      return;
    }

    const argv = Array.isArray(job.argv) ? job.argv.slice() : [];
    process.argv = argv;
    process.exitCode = 0;

    scriptFinish = (code) => {
      process.removeListener('beforeExit', onBeforeExit);
      reply({ exitCode: Number(code ?? 0) | 0 });
    };
    const onBeforeExit = () => finishScript(process.exitCode ?? 0);
    process.on('beforeExit', onBeforeExit);

    const entry = argv[1];
    if (!entry) {
      throw new Error('node: script path is missing');
    }
    const path = require('path');
    const resolvedEntry = path.isAbsolute(entry) ? entry : path.resolve(process.cwd(), entry);
    if (resolvedEntry.endsWith('.mjs')) {
      await import(require('url').pathToFileURL(resolvedEntry).href);
    } else {
      delete require.cache[require.resolve(resolvedEntry)];
      require(resolvedEntry);
    }
  } catch (err) {
    if (err instanceof TermxExit) {
      if (scriptFinish) {
        finishScript(err.termxExitCode);
      } else {
        reply({ exitCode: err.termxExitCode });
      }
      return;
    }
    scriptFinish = null;
    const message = String(err && err.stack ? err.stack : err);
    try { process.stderr.write(message + '\n'); } catch (_) { /* ignore */ }
    reply({ exitCode: 1, error: message });
  }
}

if (jobFD >= 0 && jobReplyFD >= 0) {
  const net = require('net');
  const intake = new net.Socket({ fd: jobFD, readable: true, writable: false });
  intakeSocket = intake;

  let partial = '';
  let running = false;
  const queue = [];

  function startNext() {
    if (running || queue.length === 0) return;
    running = true;
    intake.unref();
    const job = queue.shift();
    runJob(job, () => {
      abortRunningJob = null;
      running = false;
      intake.ref();
      setTimeout(() => startNext(), 0);
    }).catch((jobErr) => {
      abortRunningJob = null;
      running = false;
      intake.ref();
      writeReply({ exitCode: 1, error: String(jobErr) });
      setTimeout(() => startNext(), 0);
    });
  }

  intake.on('data', (chunk) => {
    partial += chunk.toString('utf8');
    let idx;
    while ((idx = partial.indexOf('\n')) >= 0) {
      const line = partial.slice(0, idx).trim();
      partial = partial.slice(idx + 1);
      if (line) {
        let parsed;
        try {
          parsed = JSON.parse(line);
        } catch (e) {
          writeReply({ exitCode: 1, error: 'bad job line: ' + String(e) });
          continue;
        }
        if (parsed.kind === 'cancel') {
          if (abortRunningJob) abortRunningJob();
          continue;
        }
        queue.push(parsed);
      }
    }
    startNext();
  });
  intake.on('error', (e) => {
    writeReply({ exitCode: 1, error: 'job intake error: ' + String(e) });
  });

  writeReply({ ready: true });
}
