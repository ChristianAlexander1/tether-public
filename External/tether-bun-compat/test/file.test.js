'use strict';

const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const fsReal = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { createFileApi } = require('../lib/file');
const { makeFakeFs } = require('./fake-fs');

test('Bun.file returns a lazy object with expected shape', () => {
  const fs = makeFakeFs();
  const { file } = createFileApi(fs);
  const f = file('/tmp/whatever.txt');
  assert.equal(f.name, '/tmp/whatever.txt');
  assert.equal(f.type, 'text/plain;charset=utf-8');
  assert.equal(typeof f.exists, 'function');
  assert.equal(typeof f.text, 'function');
  assert.equal(typeof f.bytes, 'function');
  assert.equal(typeof f.arrayBuffer, 'function');
  assert.equal(typeof f.json, 'function');
  assert.equal(typeof f.stream, 'function');
});

test('Bun.file type uses the extension MIME table', () => {
  const fs = makeFakeFs();
  const { file } = createFileApi(fs);
  assert.equal(file('/x/data.json').type, 'application/json;charset=utf-8');
  assert.equal(file('/x/app.wasm').type, 'application/wasm');
  assert.equal(file('/x/index.html').type, 'text/html;charset=utf-8');
  assert.equal(file('/x/app.js').type, 'text/javascript;charset=utf-8');
  assert.equal(file('/x/noext').type, 'application/octet-stream');
  assert.equal(file('/x/x.UNKNOWN').type, 'application/octet-stream');
});

test('Bun.file on missing path: size 0, exists false, text rejects ENOENT', async () => {
  const fs = makeFakeFs();
  const { file } = createFileApi(fs);
  const f = file('/does/not/exist.txt');
  assert.equal(f.size, 0);
  assert.equal(await f.exists(), false);
  await assert.rejects(f.text(), (err) => err.code === 'ENOENT');
  await assert.rejects(f.bytes(), (err) => err.code === 'ENOENT');
  await assert.rejects(f.arrayBuffer(), (err) => err.code === 'ENOENT');
});

test('Bun.file on an existing file: size, text, bytes, arrayBuffer, json', async () => {
  const fs = makeFakeFs();
  fs.addFile('/data/hello.txt', { content: 'hello, world' });
  fs.addFile('/data/obj.json', { content: JSON.stringify({ a: 1, b: [2, 3] }) });
  const { file } = createFileApi(fs);

  const t = file('/data/hello.txt');
  assert.equal(t.size, 12);
  assert.equal(await t.exists(), true);
  assert.equal(await t.text(), 'hello, world');

  const b = await t.bytes();
  assert.ok(b instanceof Uint8Array);
  assert.equal(b.length, 12);

  const ab = await t.arrayBuffer();
  assert.ok(ab instanceof ArrayBuffer);
  assert.equal(ab.byteLength, 12);

  const j = await file('/data/obj.json').json();
  assert.deepEqual(j, { a: 1, b: [2, 3] });
});

test('Bun.file.stream returns a WHATWG ReadableStream of bytes', async () => {
  const fs = makeFakeFs();
  fs.addFile('/data/log.txt', { content: 'line1\nline2\n' });
  const { file } = createFileApi(fs);
  const stream = file('/data/log.txt').stream();
  assert.ok(stream instanceof ReadableStream);
  const reader = stream.getReader();
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  const total = Buffer.concat(chunks.map(c => Buffer.from(c)));
  assert.equal(total.toString('utf8'), 'line1\nline2\n');
});

test('Bun.write string -> file returns byte count (bytes, not chars)', async () => {
  const fs = makeFakeFs();
  const { write } = createFileApi(fs);
  // "héllo" = 6 bytes (é is 2 UTF-8 bytes), 5 chars.
  const n = await write('/out/msg.txt', 'héllo');
  assert.equal(n, Buffer.byteLength('héllo'));
  assert.equal(n, 6);
  assert.deepEqual(fs.files.get('/out/msg.txt').content, Buffer.from('héllo'));
});

test('Bun.write auto-creates nested parent directories', async () => {
  const fs = makeFakeFs();
  const { write } = createFileApi(fs);
  const n = await write('/deeply/nested/dir/file.txt', 'x');
  assert.equal(n, 1);
  assert.ok(fs.has('/deeply/nested/dir'));
  assert.ok(fs.has('/deeply/nested/dir/file.txt'));
});

test('Bun.write accepts Uint8Array and ArrayBuffer', async () => {
  const fs = makeFakeFs();
  const { write } = createFileApi(fs);
  const u8 = new Uint8Array([1, 2, 3, 250]);
  const n1 = await write('/out/a.bin', u8);
  assert.equal(n1, 4);
  assert.deepEqual([...fs.files.get('/out/a.bin').content], [1, 2, 3, 250]);

  const ab = new ArrayBuffer(3);
  new Uint8Array(ab).set([9, 8, 7]);
  const n2 = await write('/out/b.bin', ab);
  assert.equal(n2, 3);
  assert.deepEqual([...fs.files.get('/out/b.bin').content], [9, 8, 7]);
});

test('Bun.write copies a BunFile into another path', async () => {
  const fs = makeFakeFs();
  fs.addFile('/src/data.bin', { content: Buffer.from([0xde, 0xad, 0xbe, 0xef]) });
  const { file, write } = createFileApi(fs);
  const src = file('/src/data.bin');
  const n = await write('/dst/copy.bin', src);
  assert.equal(n, 4);
  assert.deepEqual(
    [...fs.files.get('/dst/copy.bin').content],
    [0xde, 0xad, 0xbe, 0xef]
  );
});

test('Bun.write rejects unsupported data types', async () => {
  const fs = makeFakeFs();
  const { write } = createFileApi(fs);
  await assert.rejects(write('/out/bad.txt', { not: 'valid' }), TypeError);
});

// — Real filesystem section (permitted by the brief) —
let tmpRoot;
test('real fs round-trip: write + file.text/json/bytes', async () => {
  tmpRoot = fsReal.mkdtempSync(path.join(os.tmpdir(), 'tbc-'));
  const realFs = {
    constants: fsReal.constants,
    statSync: fsReal.statSync,
    accessSync: fsReal.accessSync,
    access: fsReal.access,
    readFile: fsReal.readFile,
    writeFile: fsReal.writeFile,
    mkdir: fsReal.mkdir,
    createReadStream: fsReal.createReadStream,
  };
  const { file, write } = createFileApi(realFs);
  const p = path.join(tmpRoot, 'sub', 'greeting.txt');
  const n = await write(p, 'hi from node');
  assert.equal(n, 12);
  const f = file(p);
  assert.equal(await f.text(), 'hi from node');
  assert.equal(f.size, 12);
  assert.equal(await f.exists(), true);
});

after(() => {
  if (tmpRoot) {
    fsReal.rmSync(tmpRoot, { recursive: true, force: true });
  }
});
