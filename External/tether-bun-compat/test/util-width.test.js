'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { stringWidth } = require('../lib/util');

test('stringWidth: ascii printable = 1 per char', () => {
  assert.equal(stringWidth('hello'), 5);
  assert.equal(stringWidth(''), 0);
  assert.equal(stringWidth('a b c'), 5);
});

test('stringWidth: combining marks count as 0 ("héllo" == 5)', () => {
  // "héllo" where é is e + combining acute accent (U+0301).
  const eComposed = 'héllo';
  const eCombined = 'he\u0301llo';
  assert.equal(stringWidth(eComposed), 5);
  assert.equal(stringWidth(eCombined), 5);
});

test('stringWidth: zero-width joiners / variation selectors count 0', () => {
  assert.equal(stringWidth('a\u200Db'), 2); // ZWJ between two ascii
  assert.equal(stringWidth('\uFE0F'), 0);
});

test('stringWidth: CJK wide chars count 2 ("你好" == 4)', () => {
  assert.equal(stringWidth('你好'), 4);
  assert.equal(stringWidth('你'), 2);
});

test('stringWidth: ANSI color sequences are stripped ("red" == 3)', () => {
  assert.equal(stringWidth('\u001b[31mred\u001b[0m'), 3);
});

test('stringWidth: emoji count as width 2', () => {
  assert.equal(stringWidth('😀'), 2);
  assert.equal(stringWidth('🎉'), 2);
  assert.equal(stringWidth('a😀b'), 4);
});

test('stringWidth: control characters contribute 0 width', () => {
  assert.equal(stringWidth('a\nb'), 2);
  assert.equal(stringWidth('\t'), 0);
});

test('stringWidth: fullwidth ASCII counts 2', () => {
  assert.equal(stringWidth('Ａ'), 2); // U+FF21 fullwidth A
});

test('stringWidth: non-string input yields 0', () => {
  assert.equal(stringWidth(null), 0);
  assert.equal(stringWidth(undefined), 0);
  assert.equal(stringWidth(42), 0);
});
