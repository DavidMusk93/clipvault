/**
 * Notes source find/replace: one matcher, VS Code semantics, Apple surface.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'path';
import test from 'node:test';
import { root } from './helpers/src.mjs';
import { findRanges, replacementChanges } from '../web/notes-find.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const entry = readFileSync(join(root, 'web/assets/notes-editor/entry.js'), 'utf8');
const css = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.css'), 'utf8');
const vendor = readFileSync(join(root, 'scripts/vendor-notes-editor.sh'), 'utf8');
const js = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.js'), 'utf8');
const taste = readFileSync(join(root, 'docs/design-taste.md'), 'utf8');

test('one matcher: case, whole word, tokens, literal metacharacters', () => {
  const text = 'Foo foo FOO foobar';
  assert.equal(findRanges(text, { query: 'foo' }).length, 4);
  assert.equal(findRanges(text, { query: 'foo', caseSensitive: true }).length, 2);
  assert.deepEqual(
    findRanges(text, { query: 'foo', wholeWord: true }).map((r) => text.slice(r.from, r.to)),
    ['Foo', 'foo', 'FOO'],
  );
  // Unicode word boundaries: 笔记 is a word only when delimited, never inside
  // 中文笔记 or 笔记本.
  assert.equal(findRanges('中文 笔记 笔记本', { query: '笔记', wholeWord: true }).length, 1);
  assert.equal(findRanges('中文笔记 笔记本', { query: '笔记', wholeWord: true }).length, 0);
  assert.equal(findRanges('中文笔记 笔记本', { query: '笔记' }).length, 2);
  assert.equal(findRanges('C++ and a.b; not aXb', { query: 'C++' }).length, 1);
  assert.equal(findRanges('C++ and a.b; not aXb', { query: 'a.b' }).length, 1);
  assert.deepEqual(findRanges('x --ip 10.20.30.40', { tokens: ['--ip', '10.20'] }).length, 2);
  assert.deepEqual(findRanges('anything', { query: '' }), []);
  assert.deepEqual(findRanges('anything', { tokens: [] }), []);
});

test('replacement changes cover every range in one transaction', () => {
  const ranges = findRanges('a foo b foo c', { query: 'foo' });
  assert.deepEqual(replacementChanges(ranges, 'bar'), [
    { from: 2, to: 5, insert: 'bar' },
    { from: 8, to: 11, insert: 'bar' },
  ]);
  assert.deepEqual(replacementChanges(null, 'x'), []);
});

test('editor exposes find/replace and uses the shared matcher', () => {
  assert.match(entry, /from '\.\.\/\.\.\/notes-find\.mjs'/);
  assert.match(entry, /startFind\(opts\)/);
  assert.match(entry, /replaceCurrent\(replacement\)/);
  assert.match(entry, /replaceAll\(replacement\)/);
  assert.match(entry, /notes-findbar/);
  assert.match(entry, /notes_find_replace/);
  assert.match(entry, /input\.replace\.all/);
  assert.match(entry, /caseSensitive: findCase/);
  assert.match(entry, /wholeWord: findWord/);
  assert.match(entry, /clipvault\.notes\.find\.case/);
  assert.match(entry, /clipvault\.notes\.find\.word/);
  assert.match(entry, /无结果/);
  assert.match(vendor, /web\/notes-find\.mjs/);
  // The shipped bundle really carries the bar and the replace metric.
  assert.match(js, /notes-findbar/);
  assert.match(js, /notes_find_replace/);
});

test('find bar is one Apple surface, not a second modal', () => {
  assert.match(css, /\.notes-findbar \{[\s\S]{0,700}background: #f6f6f8/);
  assert.match(css, /\.notes-findbar \{[\s\S]{0,700}border-radius: 12px/);
  assert.match(css, /\.notes-findbar-row \+ \.notes-findbar-row \{[\s\S]{0,160}border-top: 0\.5px/);
  assert.match(css, /\.notes-findbar-count \{[\s\S]{0,200}tabular-nums/);
  assert.match(css, /\.notes-findbar-opt\.is-on \{[\s\S]{0,120}#0071e3/);
  assert.doesNotMatch(css, /\.notes-findbar[\s\S]{0,400}backdrop-filter/);
  assert.match(css, /prefers-reduced-motion: reduce\) \{\s*\.notes-findbar \{ animation: none; \}/);
  assert.match(css, /::highlight\(cv-notes-find\)/);
});

test('panel keyboard mirrors VS Code and never fights the panel', () => {
  assert.match(html, /data-act="find"/);
  assert.match(html, /notesState\.editor\.startFind\?\.\(\{ replace: false \}\)/);
  assert.match(html, /ed\.startFind\(\{ replace: !!e\.altKey \}\)/);
  assert.match(html, /notesState\.editor\?\.isFindOpen\?\.\(\)/);
  assert.match(html, /notesState\.editor\.closeFind\(\)/);
  assert.match(html, /notesState\.editor\.stepFind\(e\.shiftKey \? -1 : 1\)/);
  assert.match(html, /notes-editor\.css\?v=n33/);
  assert.match(html, /notes-editor\.js\?v=n33/);
  assert.match(taste, /\| 查找 \/ 替换 \|/);
});
