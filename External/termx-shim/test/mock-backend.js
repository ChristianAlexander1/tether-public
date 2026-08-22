'use strict';

/**
 * test/mock-backend.js — a fake TermX command engine that implements the wire
 * protocol (one JSON line request -> one JSON line reply), so the entire shim
 * runs with no app, no Swift, no iOS.
 *
 * Two ways to use it:
 *   1. In-process fake:  mockBackend.createInProcessTransport() returns a
 *      synchronous transport you can inject with ipc.setTransport(...).
 *   2. Standalone server: run `node mock-backend.js [socketPath]` (or set
 *      TERMX_IPC_SOCKET) and point the shim at it via TERMX_IPC_SOCKET, to test
 *      the real wire protocol across processes.
 *
 * Tests drive output by registering "programs" with this module. Anything not
 * registered is reported as `spawn <file> ENOENT`.
 */

const net = require('net');

const programs = new Map();
const requests = [];
let nextPid = 1000;

const SLEEP = new Int32Array(new SharedArrayBuffer(4));
function sleep(ms) {
  Atomics.wait(SLEEP, 0, 0, ms > 0 ? ms : 0);
}

/**
 * Register a canned program.
 * @param name  file name as sent in by the shim (e.g. 'sh', '/bin/sh', 'cat')
 * @param spec  { stdout, stderr, exitCode, delay, stdoutFromInput, signal,
 *                fn?: (req) => {stdout,stderr,exitCode,delay,signal} }
 */
function register(name, spec) {
  programs.set(name, Object.assign({}, spec));
}

function clear() {
  programs.clear();
  requests.length = 0;
  nextPid = 1000;
}

function program(name) {
  return programs.get(name);
}

function handleSpawn(req) {
  const pid = nextPid++;
  const enc = req.encoding || 'utf8';
  const spec = programs.get(req.file);
  if (!spec) {
    return {
      pid,
      exitCode: null,
      stdout: '',
      stderr: '',
      signal: null,
      error: 'spawn ' + req.file + ' ENOENT',
      code: 'ENOENT',
      encoding: enc,
    };
  }

  const body = typeof spec.fn === 'function' ? spec.fn(req) || {} : spec;
  const runTime = body.delay || 0;

  // Simulate the app enforcing an in-flight timeout.
  if (req.timeout != null && runTime >= req.timeout) {
    sleep(req.timeout);
    return {
      pid,
      exitCode: null,
      stdout: '',
      stderr: '',
      signal: req.killSignal || 'SIGTERM',
      error: null,
      code: null,
      encoding: enc,
    };
  }

  if (runTime > 0) sleep(runTime);

  const stdout = body.stdoutFromInput
    ? String(req.input == null ? '' : req.input)
    : body.stdout || '';
  const stderr = body.stderr || '';
  const exitCode = body.exitCode != null ? body.exitCode : 0;

  return {
    pid,
    exitCode,
    stdout,
    stderr,
    signal: body.signal || null,
    error: null,
    code: null,
    encoding: enc,
  };
}

function handleRequest(req) {
  requests.push(req);
  if (req.op === 'signal') return { ok: true };
  if (req.op === 'spawn' || req.op === 'spawnSync') return handleSpawn(req);
  return { error: 'unknown op ' + req.op };
}

/** Synchronous in-process transport for ipc.setTransport(...). */
function createInProcessTransport() {
  return function inProcessTransport(request) {
    return handleRequest(request);
  };
}

/** Run a standalone Unix-socket server implementing the protocol. */
function runStandaloneServer(socketPath) {
  if (!socketPath) throw new Error('mock-backend: no socket path (argv[2] or TERMX_IPC_SOCKET)');
  // A couple of always-available defaults so a wire test can exercise a real
  // command without needing to register programs in the child process.
  register('cat', { stdoutFromInput: true });
  register('/bin/sh', { fn: () => ({ stdout: 'sh ran\n', stderr: '', exitCode: 0 }) });
  register('prog', { stdout: 'over the wire\n', exitCode: 0 });
  const server = net.createServer((conn) => {
    let buf = '';
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      let idx;
      while ((idx = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (!line.trim()) continue;
        const reply = handleRequest(JSON.parse(line));
        conn.write(JSON.stringify(reply) + '\n');
      }
    });
  });
  server.listen(socketPath, () => {
    process.stdout.write('LISTENING\n');
  });
  server.on('error', (err) => {
    process.stderr.write('ERR ' + err.message + '\n');
    process.exit(1);
  });
}

module.exports = {
  register,
  clear,
  program,
  requests,
  handleRequest,
  createInProcessTransport,
  runStandaloneServer,
  _sleep: sleep,
};

if (require.main === module) {
  runStandaloneServer(process.argv[2] || process.env.TERMX_IPC_SOCKET);
}
