'use strict';

// In-process TJIP/2 mock server — executable documentation of the wire spec.
//
// - Full framing (4-byte BE length + JSON), envelope validation, v:2.
// - Handshake: client sends `hello`; the server replies with ttyFds/cols/
//   rows/termName/colorTerm. Records every hello body (role assertions).
// - tty domain: tty.get / tty.setRawMode (EINVAL for non-TTY fds) /
//   tty.windowSize.
// - spawn domain: spawn.start (ENOENT for unresolvable argv[0]),
//   spawn.stdin (window responses), spawn.stdinEnd, spawn.kill (ESRCH after
//   exit), spawn.resize (EINVAL unless pty:true).
// - flow domain: enforces the <= 262,144-byte unacked in-flight window per
//   pid; queued output is released as flow.ack arrives. Acks are tallied per
//   pid so tests can assert exact totals.
// - Unknown req types → {ok:false, code:"ENOSYS"}; server-initiated requests
//   are supported (sendRequest) so the client's ENOSYS answer is testable.
// - Raw byte injection (injectRaw / injectChunks) for framing edge cases.
//
// Frame processing is SYNCHRONOUS inside write(): the client's write() call
// directly drives server logic, and responses are pushed into the client
// stream's readable buffer in the same tick. That is what makes the
// spawnSync two-connection design testable with in-process streams.

const { EventEmitter } = require('node:events');
const { Duplex } = require('node:stream');
const { encodeFrame, FrameParser, MAX_FRAME_BYTES } = require('../../lib/ipc/framing');

const FLOW_WINDOW = 262144; // server keeps <= 256 KiB unacked in flight per pid
const RAW_CHUNK_MAX = 65536;

class MockServer extends EventEmitter {
  /**
   * @param {object} [config]
   * @param {number[]} [config.ttyFds=[0,1,2]]   genuinely PTY-bound fds
   * @param {number} [config.cols=80]
   * @param {number} [config.rows=24]
   * @param {string} [config.termName='xterm-256color']
   * @param {string} [config.colorTerm='truecolor']
   * @param {string[]} [config.features]
   * @param {string[]|((argv:string[])=>boolean)} [config.unresolvable]
   *        argv[0] values that spawn.start must reject with ENOENT
   * @param {number} [config.flowWindow=262144]
   */
  constructor(config = {}) {
    super();
    this.config = {
      ttyFds: [0, 1, 2],
      cols: 80,
      rows: 24,
      termName: 'xterm-256color',
      colorTerm: 'truecolor',
      features: ['tty', 'spawn', 'flow'],
      flowWindow: FLOW_WINDOW,
      unresolvable: [],
      ...config,
    };
    this.connections = [];
    this.hellos = []; // every hello body seen (role/proto assertions)
    this.requests = []; // every req envelope seen (in order)
    this.responses = []; // every res envelope seen from the client
    this.events = []; // every evt envelope seen from the client
    this.acks = new Map(); // pid → total acked bytes
    this.processes = new Map(); // pid → proc state (alive only)
    this.isRaw = new Map(); // fd → boolean
    this._nextPid = 4200;
    this._serverReqId = 0;
    this._hooks = new Map();
    this._failOnce = new Map();
  }

  // ------------------------------------------------------------- connection

  /**
   * Create the client end of a fresh in-process connection.
   * @returns {import('node:stream').Duplex}
   */
  createConnection() {
    const server = this;
    const conn = {
      server,
      parser: new FrameParser((env) => server._onEnvelope(conn, env)),
      stream: null,
      closed: false,
    };
    const stream = new Duplex({
      read() {
        /* data is pushed by conn.send */
      },
      write(chunk, encoding, callback) {
        try {
          conn.parser.consume(chunk);
        } catch (err) {
          server.emit('clientProtocolError', err);
        }
        callback();
      },
    });
    conn.stream = stream;
    conn.send = (envelope) => {
      if (!conn.closed) stream.push(encodeFrame(envelope));
    };
    this.connections.push(conn);
    return stream;
  }

  /** Alias matching the install({connect}) vocabulary. */
  connect() {
    return this.createConnection();
  }

  // --------------------------------------------------------- raw byte tools

  /** Push raw bytes to every connection (bypasses framing). */
  injectRaw(buf) {
    for (const conn of this.connections) {
      if (!conn.closed) conn.stream.push(buf);
    }
  }

  /** Push a list of raw byte chunks to every connection, in order. */
  injectChunks(chunks) {
    for (const chunk of chunks) this.injectRaw(chunk);
  }

  // ------------------------------------------------------------- server → C

  /** Broadcast an evt (no id) to every connection. */
  push(type, body) {
    for (const conn of this.connections) {
      conn.send({ v: 2, kind: 'evt', type, body });
    }
  }

  /**
   * Send a server-initiated req to every connection; returns the id used.
   * The client must answer with exactly one res carrying the same id.
   */
  sendRequest(type, body = {}) {
    this._serverReqId += 1;
    const id = -this._serverReqId; // negative ids keep the two id spaces disjoint
    for (const conn of this.connections) {
      conn.send({ v: 2, kind: 'req', id, type, body });
    }
    return id;
  }

  // ------------------------------------------------------------- scripting

  /** Override the response for a request type: fn(body, conn, env) → body. */
  hook(type, fn) {
    this._hooks.set(type, fn);
  }

  /** Force the NEXT request of `type` to fail: {code, message}. */
  failOnce(type, res) {
    this._failOnce.set(type, res);
  }

  /** Register a fake process; returns its state. Used by spawn.start. */
  registerProcess(body) {
    const pid = this._nextPid++;
    const proc = {
      pid,
      argv: Array.isArray(body.argv) ? body.argv.slice() : [],
      pty: !!body.pty,
      window: 65536, // stdin window reported by spawn.stdin responses
      alive: true,
      stdin: [], // decoded stdin chunks received
      stdinEnded: false,
      pendingOutput: [], // {kind, buf} awaiting flow window
      inFlight: 0, // unacked bytes currently pushed to the client
    };
    this.processes.set(pid, proc);
    return proc;
  }

  /** Set the stdin window reported by future spawn.stdin responses. */
  setWindow(pid, window) {
    const proc = this.processes.get(pid);
    if (!proc) throw new Error(`no such mock process: ${pid}`);
    proc.window = window;
  }

  /**
   * Queue output for a pid, delivered in <= chunkSize raw chunks subject to
   * the flow window (more is released as flow.ack arrives).
   */
  queueOutput(pid, kind, data, chunkSize = RAW_CHUNK_MAX) {
    const proc = this.processes.get(pid);
    if (!proc) throw new Error(`no such mock process: ${pid}`);
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
    for (let offset = 0; offset < buf.length; offset += chunkSize) {
      proc.pendingOutput.push({ kind, buf: buf.subarray(offset, offset + chunkSize) });
    }
    this._flushOutput(proc);
  }

  _flushOutput(proc) {
    while (proc.pendingOutput.length > 0) {
      const next = proc.pendingOutput[0];
      if (proc.inFlight + next.buf.length > this.config.flowWindow) return; // window full
      proc.pendingOutput.shift();
      proc.inFlight += next.buf.length;
      this.push(`spawn.${next.kind}`, { pid: proc.pid, dataB64: next.buf.toString('base64') });
    }
  }

  /**
   * End a process: flush any remaining queued output (a real server delivers
   * everything before the final exit), then push exactly one spawn.exit.
   * code/signal are mutually exclusive.
   */
  exitProcess(pid, code = 0, signal = null) {
    const proc = this.processes.get(pid);
    if (!proc) throw new Error(`no such mock process: ${pid}`);
    while (proc.pendingOutput.length > 0) {
      const next = proc.pendingOutput.shift();
      proc.inFlight += next.buf.length;
      this.push(`spawn.${next.kind}`, { pid, dataB64: next.buf.toString('base64') });
    }
    proc.alive = false;
    this.processes.delete(pid); // kill after exit → ESRCH
    const exitBody = signal
      ? { pid, code: null, signal }
      : { pid, code: code === undefined ? null : code, signal: null };
    this.push('spawn.exit', exitBody);
  }

  /** Push a tty.resize event. */
  resize(cols, rows) {
    this.push('tty.resize', { cols, rows });
  }

  /** Push a tty.signal event. */
  signal(name) {
    this.push('tty.signal', { signal: name });
  }

  /** Close every connection (client should treat this as fatal). */
  closeAll() {
    for (const conn of this.connections) {
      conn.closed = true;
      conn.stream.destroy(); // fires 'close' on the client side
    }
  }

  // -------------------------------------------------------------- dispatch

  _onEnvelope(conn, env) {
    this.emit('envelope', env);
    if (env.kind === 'req') this._onRequest(conn, env);
    else if (env.kind === 'res') {
      this.responses.push(env);
      this.emit('res', env);
    } else if (env.kind === 'evt') {
      this.events.push(env);
      this._onEvent(conn, env);
    }
  }

  _onRequest(conn, env) {
    this.requests.push(env);
    this.emit('req', env);

    const fail = this._failOnce.get(env.type);
    if (fail) {
      this._failOnce.delete(env.type);
      conn.send({
        v: 2,
        kind: 'res',
        id: env.id,
        type: env.type,
        body: { ok: false, code: fail.code, message: fail.message || fail.code },
      });
      return;
    }

    const hook = this._hooks.get(env.type);
    const body = hook ? hook(env.body || {}, conn, env) : this._defaultHandler(env.type, env.body || {});
    const sendRes = (resolved) => {
      conn.send({ v: 2, kind: 'res', id: env.id, type: env.type, body: resolved });
    };
    if (body && typeof body.then === 'function') {
      body.then(sendRes); // async hook
    } else {
      // Synchronous reply: critical for the spawnSync sync-pump design, where
      // the client's write() must find the response already buffered.
      sendRes(body);
    }
  }

  _defaultHandler(type, body) {
    switch (type) {
      case 'hello': {
        this.hellos.push(body);
        if (body.proto !== 2) {
          return { ok: false, code: 'EPROTO', message: `unsupported proto ${body.proto}` };
        }
        return {
          ok: true,
          proto: 2,
          features: this.config.features.slice(),
          ttyFds: this.config.ttyFds.slice(),
          cols: this.config.cols,
          rows: this.config.rows,
          termName: this.config.termName,
          colorTerm: this.config.colorTerm,
        };
      }

      case 'tty.get':
        return {
          ok: true,
          isTTY: this.config.ttyFds.includes(body.fd),
          isRaw: !!this.isRaw.get(body.fd),
          cols: this.config.cols,
          rows: this.config.rows,
        };

      case 'tty.setRawMode': {
        if (!this.config.ttyFds.includes(body.fd)) {
          return { ok: false, code: 'EINVAL', message: `fd ${body.fd} is not a TTY` };
        }
        const wasRaw = !!this.isRaw.get(body.fd);
        this.isRaw.set(body.fd, !!body.mode);
        return { ok: true, wasRaw };
      }

      case 'tty.windowSize':
        return { ok: true, cols: this.config.cols, rows: this.config.rows };

      case 'spawn.start': {
        const argv = Array.isArray(body.argv) ? body.argv : [];
        const unresolvable = this.config.unresolvable;
        const missing =
          typeof unresolvable === 'function'
            ? unresolvable(argv)
            : Array.isArray(unresolvable) && unresolvable.includes(argv[0]);
        if (missing) {
          return { ok: false, code: 'ENOENT', message: `command not found: ${argv[0]}` };
        }
        const proc = this.registerProcess(body);
        this.emit('spawn', proc, body);
        return { ok: true, pid: proc.pid };
      }

      case 'spawn.stdin': {
        const proc = this.processes.get(body.pid);
        if (!proc || !proc.alive) {
          return { ok: false, code: 'ESRCH', message: `no such process: ${body.pid}` };
        }
        const data = Buffer.from(body.dataB64 || '', 'base64');
        proc.stdin.push(data);
        this.emit('stdin', proc, data);
        return { ok: true, window: proc.window };
      }

      case 'spawn.stdinEnd': {
        const proc = this.processes.get(body.pid);
        if (!proc || !proc.alive) {
          return { ok: false, code: 'ESRCH', message: `no such process: ${body.pid}` };
        }
        proc.stdinEnded = true;
        this.emit('stdinEnd', proc);
        return { ok: true };
      }

      case 'spawn.kill': {
        const proc = this.processes.get(body.pid);
        if (!proc || !proc.alive) {
          return { ok: false, code: 'ESRCH', message: `no such process: ${body.pid}` };
        }
        const signal = body.signal || 'SIGTERM';
        this.exitProcess(body.pid, null, signal);
        return { ok: true };
      }

      case 'spawn.resize': {
        const proc = this.processes.get(body.pid);
        if (!proc || !proc.alive) {
          return { ok: false, code: 'ESRCH', message: `no such process: ${body.pid}` };
        }
        if (!proc.pty) {
          return { ok: false, code: 'EINVAL', message: 'process is not attached to a pty' };
        }
        proc.cols = body.cols;
        proc.rows = body.rows;
        return { ok: true };
      }

      default:
        // Unknown req types → ENOSYS (spec).
        return { ok: false, code: 'ENOSYS', message: `unknown request type: ${type}` };
    }
  }

  _onEvent(conn, env) {
    if (env.type === 'flow.ack') {
      const pid = env.body.pid;
      const bytes = Number.isInteger(env.body.bytes) ? env.body.bytes : 0;
      this.acks.set(pid, (this.acks.get(pid) || 0) + bytes);
      this.emit('ack', pid, bytes, this.acks.get(pid));
      const proc = this.processes.get(pid);
      if (proc) {
        proc.inFlight = Math.max(0, proc.inFlight - bytes);
        this._flushOutput(proc); // release more output as the window frees up
      }
      return;
    }
    this.emit('evt', env.type, env.body);
  }

  // -------------------------------------------------------------- helpers

  totalAcked(pid) {
    return this.acks.get(pid) || 0;
  }

  requestsOfType(type) {
    return this.requests.filter((env) => env.type === type);
  }

  eventsOfType(type) {
    return this.events.filter((env) => env.type === type);
  }
}

module.exports = { MockServer, FLOW_WINDOW, RAW_CHUNK_MAX, MAX_FRAME_BYTES, encodeFrame };
