'use strict';

const fs = require('fs');
const net = require('net');
const { EventEmitter } = require('events');

function envInt(name) {
  const v = process.env[name];
  if (v == null || v === '') return null;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

function ipcSockPath() {
  return process.env.TETHER_IPC_SOCK || process.env.TERMX_IPC_SOCKET || null;
}

function ipcWriteFd() {
  return envInt('TETHER_IPC_FD') ?? envInt('TERMX_IPC_FD');
}

function ipcReplyFd() {
  return envInt('TETHER_IPC_REPLY_FD') ?? envInt('TERMX_IPC_REPLY_FD');
}

function realChildProcess() {
  const Module = require('module');
  const orig = Module._load;
  if (typeof orig._tetherOriginalLoad === 'function') {
    return orig._tetherOriginalLoad('child_process', module, false);
  }
  return require('node:child_process');
}

class IpcClient extends EventEmitter {
  constructor() {
    super();
    this._pending = [];
    this._buf = '';
    this._connected = false;
    this._writeStream = null;
    this._readStream = null;
    this._socket = null;
  }

  connect() {
    if (this._connected) return this;
    const sock = ipcSockPath();
    const writeFd = ipcWriteFd();
    const replyFd = ipcReplyFd();

    if (sock) {
      this._connectSock(sock);
    } else if (writeFd != null && replyFd != null) {
      this._connectFds(writeFd, replyFd);
    } else {
      const err = new Error(
        'Tether IPC not configured: set TETHER_IPC_SOCK / TERMX_IPC_SOCKET or IPC fd pair'
      );
      err.code = 'ENOIPC';
      throw err;
    }
    return this;
  }

  _connectFds(writeFd, replyFd) {
    this._writeStream = fs.createWriteStream(null, { fd: writeFd, autoClose: false });
    this._readStream = fs.createReadStream(null, { fd: replyFd, autoClose: false });
    this._readStream.setEncoding('utf8');
    this._readStream.on('data', (chunk) => this._onData(chunk));
    this._readStream.on('error', (e) => this.emit('error', e));
    this._writeStream.on('error', (e) => this.emit('error', e));
    this._connected = true;
  }

  _connectSock(sockPath) {
    const sock = net.connect({ path: sockPath });
    this._socket = sock;
    sock.setEncoding('utf8');
    sock.on('data', (chunk) => this._onData(chunk));
    sock.on('error', (e) => this.emit('error', e));
    sock.on('connect', () => {
      if (typeof sock.unref === 'function') sock.unref();
      this.emit('connect');
    });
    this._writeStream = sock;
    this._readStream = sock;
    this._connected = true;
  }

  _onData(chunk) {
    this._buf += chunk;
    let idx;
    while ((idx = this._buf.indexOf('\n')) !== -1) {
      const line = this._buf.slice(0, idx);
      this._buf = this._buf.slice(idx + 1);
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (e) {
        this.emit('error', e);
        continue;
      }
      const waiter = this._pending.shift();
      if (waiter) waiter.resolve(msg);
      this.emit('message', msg);
    }
  }

  send(obj) {
    const line = JSON.stringify(obj) + '\n';
    return new Promise((resolve, reject) => {
      this._pending.push({ resolve, reject });
      const ws = this._writeStream;
      if (!ws) {
        this._pending.pop();
        return reject(new Error('IPC not connected'));
      }
      try {
        ws.write(line);
      } catch (e) {
        this._pending.pop();
        return reject(e);
      }
    });
  }

  close() {
    if (this._socket) {
      try {
        this._socket.destroy();
      } catch (_) {}
    }
    this._connected = false;
  }
}

let _shared = null;

function getClient() {
  if (!_shared) {
    _shared = new IpcClient();
    _shared.connect();
  }
  return _shared;
}

function resetClient() {
  if (_shared) {
    _shared.close();
    _shared = null;
  }
}

function sendRequest(obj) {
  return getClient().send(obj);
}

function sendRequestSync(obj, timeoutMs) {
  const sockPath = ipcSockPath();
  const writeFd = ipcWriteFd();
  const replyFd = ipcReplyFd();
  const timeout = timeoutMs == null ? 60000 : timeoutMs;

  if (writeFd != null && replyFd != null) {
    const line = JSON.stringify(obj) + '\n';
    fs.writeSync(writeFd, line);
    return readSyncLine(replyFd, timeout);
  }

  if (sockPath) {
    return sendSyncViaHelper(sockPath, obj, timeout);
  }

  throw Object.assign(new Error('Tether IPC not configured'), { code: 'ENOIPC' });
}

function readSyncLine(fd, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let acc = '';
  const buf = Buffer.alloc(4096);
  while (Date.now() < deadline) {
    let n = 0;
    try {
      n = fs.readSync(fd, buf, 0, buf.length, null);
    } catch (e) {
      if (e.code === 'EAGAIN' || e.code === 'EWOULDBLOCK') continue;
      throw e;
    }
    if (n <= 0) continue;
    acc += buf.slice(0, n).toString('utf8');
    const idx = acc.indexOf('\n');
    if (idx !== -1) return JSON.parse(acc.slice(0, idx));
  }
  const e = new Error('IPC sync timeout');
  e.code = 'ETIMEDOUT';
  throw e;
}

function sendSyncViaHelper(sockPath, obj, timeoutMs) {
  const cp = realChildProcess();
  const payload = JSON.stringify(obj);
  const script = `
    const net = require('net');
    const path = process.argv[1];
    const payload = process.argv[2];
    const sock = net.connect({ path });
    let buf = '';
    sock.setEncoding('utf8');
    sock.on('connect', () => sock.write(payload + '\\n'));
    sock.on('data', (c) => {
      buf += c;
      const i = buf.indexOf('\\n');
      if (i !== -1) {
        process.stdout.write(buf.slice(0, i));
        sock.end();
        process.exit(0);
      }
    });
    sock.on('error', (e) => {
      process.stderr.write(e.message);
      process.exit(2);
    });
    setTimeout(() => process.exit(3), ${Number(timeoutMs) || 60000});
  `;
  const r = cp.spawnSync(process.execPath, ['-e', script, sockPath, payload], {
    encoding: 'utf8',
    timeout: (timeoutMs || 60000) + 2000,
  });
  if (r.status !== 0) {
    const err = new Error(r.stderr || 'IPC sync helper failed');
    err.code = r.status === 3 ? 'ETIMEDOUT' : 'EIPC';
    throw err;
  }
  return JSON.parse(r.stdout);
}

function isInteractive() {
  return (
    process.env.TETHER_INTERACTIVE === '1' ||
    process.env.TERMX_INTERACTIVE === '1'
  );
}

async function connect() {
  getClient();
  return Promise.resolve();
}

function clearTransport() {
  resetClient();
}

function roundTrip(request) {
  const req = { ...request };
  if (!req.kind && req.op) {
    if (req.op === 'spawnSync' || req.op === 'spawn') req.kind = 'spawn';
    else if (req.op === 'signal') req.kind = 'cancel';
    else req.kind = req.op;
    delete req.op;
  }
  const reply = sendRequestSync(req);
  if (!reply || typeof reply !== 'object') {
    throw new Error('Tether IPC: invalid reply');
  }
  return reply;
}

module.exports = {
  IpcClient,
  getClient,
  resetClient,
  sendRequest,
  sendRequestSync,
  connect,
  clearTransport,
  roundTrip,
  isInteractive,
};
