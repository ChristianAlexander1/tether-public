'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { deepEquals } = require('../lib/util');

test('deepEquals: primitives', () => {
  assert.equal(deepEquals(1, 1), true);
  assert.equal(deepEquals('a', 'a'), true);
  assert.equal(deepEquals(1, '1'), false);
  assert.equal(deepEquals(null, null), true);
  assert.equal(deepEquals(null, undefined), false);
  assert.equal(deepEquals(NaN, NaN), true);
  assert.equal(deepEquals(0, -0), false); // Object.is
});

test('deepEquals: plain objects and arrays', () => {
  assert.equal(deepEquals({ a: 1, b: [1, 2] }, { a: 1, b: [1, 2] }), true);
  assert.equal(deepEquals({ a: 1 }, { a: 2 }), false);
  assert.equal(deepEquals({ a: 1 }, { a: 1, b: undefined }), false);
  assert.equal(deepEquals([1, 2, 3], [1, 2, 3]), true);
  assert.equal(deepEquals([1, 2], [1, 2, 3]), false);
});

test('deepEquals: Dates and RegExps', () => {
  const d1 = new Date(1700000000000);
  const d2 = new Date(1700000000000);
  const d3 = new Date(1700000000001);
  assert.equal(deepEquals(d1, d2), true);
  assert.equal(deepEquals(d1, d3), false);
  assert.equal(deepEquals(/abc/gi, /abc/gi), true);
  assert.equal(deepEquals(/abc/g, /abc/i), false);
});

test('deepEquals: typed arrays', () => {
  assert.equal(deepEquals(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 3])), true);
  assert.equal(deepEquals(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 4])), false);
  // Different constructors are not equal.
  assert.equal(deepEquals(new Uint8Array([1]), new Uint16Array([1])), false);
});

test('deepEquals: ArrayBuffers compare byte-for-byte', () => {
  const a = new ArrayBuffer(3); new Uint8Array(a).set([7, 8, 9]);
  const b = new ArrayBuffer(3); new Uint8Array(b).set([7, 8, 9]);
  const c = new ArrayBuffer(3); new Uint8Array(c).set([7, 8, 0]);
  assert.equal(deepEquals(a, b), true);
  assert.equal(deepEquals(a, c), false);
});

test('deepEquals: Maps are order-insensitive', () => {
  const m1 = new Map([['a', 1], ['b', 2]]);
  const m2 = new Map([['b', 2], ['a', 1]]);
  const m3 = new Map([['a', 1], ['b', 3]]);
  assert.equal(deepEquals(m1, m2), true);
  assert.equal(deepEquals(m1, m3), false);
});

test('deepEquals: Sets are order-insensitive', () => {
  const s1 = new Set([1, 2, 3]);
  const s2 = new Set([3, 2, 1]);
  const s3 = new Set([1, 2]);
  assert.equal(deepEquals(s1, s2), true);
  assert.equal(deepEquals(s1, s3), false);
});

test('deepEquals: cyclic objects equal to isomorphic cyclic objects', () => {
  const a = { name: 'x' };
  a.self = a;
  const b = { name: 'x' };
  b.self = b;
  const c = { name: 'x' };
  c.self = c;
  c.extra = 1;
  assert.equal(deepEquals(a, b), true);
  assert.equal(deepEquals(a, c), false);
});

test('deepEquals: shared (non-cyclic) references compare structurally', () => {
  const child = { x: 1 };
  const a = { left: child, right: child };
  const b = { left: { x: 1 }, right: { x: 1 } };
  assert.equal(deepEquals(a, b), true);
});

test('deepEquals: strict=true distinguishes plain object from class instance', () => {
  class Pt { constructor(x, y) { this.x = x; this.y = y; } }
  const inst = new Pt(1, 2);
  const plain = { x: 1, y: 2 };
  // Non-strict: same own properties -> equal (like Bun's loose default).
  assert.equal(deepEquals(inst, plain, false), true);
  // Strict: prototypes differ -> not equal.
  assert.equal(deepEquals(inst, plain, true), false);
  assert.equal(deepEquals(new Pt(1, 2), new Pt(1, 2), true), true);
});
