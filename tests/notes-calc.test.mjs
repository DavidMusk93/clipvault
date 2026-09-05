/**
 * Notes checkpoint stamp + inline calc. No eval().
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  extractCalcExpr,
  formatCheckpoint,
  hrStampBlock,
  inFence,
  isHrLine,
  isStampLine,
  tryEval,
} from '../web/notes-calc.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const entry = readFileSync(join(root, 'web/assets/notes-editor/entry.js'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

test('tryEval does arithmetic and refuses junk', () => {
  assert.equal(tryEval('1+2'), '3');
  assert.equal(tryEval(' (3 + 4) * 2 '), '14');
  assert.equal(tryEval('2^10'), '1024');
  assert.equal(tryEval('2^3^2'), '512');
  assert.equal(tryEval('0.1+0.2'), '0.3');
  assert.equal(tryEval('10/4'), '2.5');
  assert.equal(tryEval('10%3'), '1');
  assert.equal(tryEval('-3+1'), '-2');
  assert.equal(tryEval('1×2'), '2');
  assert.equal(tryEval('8÷2'), '4');
  assert.equal(tryEval('42'), null);
  assert.equal(tryEval('1/0'), null);
  assert.equal(tryEval('foo+1'), null);
  assert.equal(tryEval('1+'), null);
  assert.equal(tryEval('price'), null);
  assert.equal(tryEval(''), null);
});

test('extractCalcExpr reads the expression before =', () => {
  assert.equal(extractCalcExpr('1+2=', 4), '1+2');
  assert.equal(extractCalcExpr('cost 1+2=', 9), '1+2');
  assert.equal(extractCalcExpr('1. 2+3=', 7), '2+3');
  assert.equal(extractCalcExpr('1.2+3=', 6), '1.2+3');
  assert.equal(extractCalcExpr('x=', 2), null);
  assert.equal(extractCalcExpr('a==', 3), null);
  assert.equal(extractCalcExpr('>=', 2), null);
  assert.equal(extractCalcExpr('`1+2=`', 5), null);
  assert.equal(tryEval(extractCalcExpr('1+2=', 4)), '3');
});

test('hr checkpoint is a separator plus local datetime on the next line', () => {
  const d = new Date(2026, 8, 5, 17, 8);
  assert.equal(formatCheckpoint(d), '2026-09-05 17:08');
  assert.equal(hrStampBlock(d), '---\n2026-09-05 17:08\n\n');
  assert.equal(isHrLine('---'), true);
  assert.equal(isHrLine('  ---  '), true);
  assert.equal(isHrLine('----'), false);
  assert.equal(isHrLine('| --- |'), false);
  assert.equal(isStampLine('2026-09-05 17:08'), true);
  assert.equal(isStampLine('hello'), false);
});

test('fences suppress checkpoint and calc', () => {
  assert.equal(inFence(['```js']), true);
  assert.equal(inFence(['```js', '1+2', '```']), false);
  assert.equal(inFence([]), false);
});

test('editor wires stamp, ghost calc, and Tab-before-indent', () => {
  assert.match(entry, /from '\.\.\/\.\.\/notes-calc\.mjs'/);
  assert.match(entry, /function stampHrCheckpoint/);
  assert.match(entry, /function acceptCalc/);
  assert.match(entry, /cm-calc-ghost/);
  const tab = entry.indexOf("{ key: 'Tab', run:");
  const accept = entry.indexOf('acceptCalc');
  const indent = entry.indexOf('indentList(v, 1)');
  assert.ok(accept > 0 && tab > 0 && indent > tab);
  assert.ok(accept < indent, 'Tab must accept calc before indenting lists');
  assert.match(check, /tests\/notes-calc\.test\.mjs/);
});
