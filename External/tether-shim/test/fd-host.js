'use strict';

const fs = require('fs');
const { handleRequest } = require('./mock-backend');

const reqPath = process.argv[2];
const repPath = process.argv[3];

const reqFd = fs.openSync(reqPath, fs.constants.O_RDWR);
const repFd = fs.openSync(repPath, fs.constants.O_RDWR);

let acc = '';
const buf = Buffer.alloc(4096);
for (;;) {
  let n = 0;
  try {
    n = fs.readSync(reqFd, buf, 0, buf.length, null);
  } catch (e) {
    if (e.code === 'EAGAIN') continue;
    throw e;
  }
  if (n <= 0) continue;
  acc += buf.slice(0, n).toString('utf8');
  let idx;
  while ((idx = acc.indexOf('\n')) !== -1) {
    const line = acc.slice(0, idx);
    acc = acc.slice(idx + 1);
    if (!line.trim()) continue;
    let req;
    try {
      req = JSON.parse(line);
    } catch (e) {
      fs.writeSync(repFd, JSON.stringify({ ok: false, stderr: String(e), exitCode: 1, stdout: '', pid: 0 }) + '\n');
      continue;
    }
    const reply = handleRequest(req);
    fs.writeSync(repFd, JSON.stringify(reply) + '\n');
  }
}
