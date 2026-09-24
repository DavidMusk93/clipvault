/**
 * Note find: the sidebar rail, the title and the editor must share one matcher.
 * Pure functions only — no CodeMirror/jsdom needed.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const entry = readFileSync(join(root, 'web/assets/notes-editor/entry.js'), 'utf8');

function fnSource(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} missing`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth += 1;
    else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`${name} unbalanced`);
}

function build(names, source) {
  const body = names.map((n) => fnSource(source, n)).join('\n');
  return new Function(`${body}\nreturn { ${names.join(', ')} };`)();
}

const side = build(
  ['escapeRegExp', 'searchTokens', 'matchRanges', 'noteExcerpt', 'decodeNoteBody', 'noteSearchSnippet'],
  html,
);
const editor = build(['escapeRegExp', 'findRanges'], entry);

test('sidebar and editor find share one matcher (tokens in, ranges out)', () => {
  const tokens = side.searchTokens('gateway 网关');
  const text = 'The gateway and 网关 both appear; Gateway again.';
  const rail = side.matchRanges(text, tokens).map((r) => [r.start, r.end]);
  const doc = editor.findRanges(text, tokens).map((r) => [r.from, r.to]);
  assert.deepEqual(rail, doc);
  assert.ok(rail.length >= 3, 'multi-token, case-insensitive, CJK');
});

test('matcher treats tokens literally (regex metacharacters stay literal)', () => {
  const tokens = side.searchTokens('a+b (c)');
  const text = 'literal a+b then (c) done';
  const hits = side.matchRanges(text, tokens).map((r) => text.slice(r.start, r.end));
  assert.deepEqual(hits, ['a+b', '(c)']);
});

test('noteSearchSnippet windows the raw body around the first hit', () => {
  const raw = '# 网关\n\n' + 'x'.repeat(200) + ' gateway ' + 'y'.repeat(200);
  const snip = side.noteSearchSnippet(raw, 'gateway');
  assert.ok(snip.includes('gateway'));
  assert.ok(snip.startsWith('…'), 'left ellipsis');
  assert.ok(snip.endsWith('…'), 'right ellipsis');
  assert.ok(snip.length < 120, 'snippet stays a rail row, not the note');
});

test('noteSearchSnippet falls back to the clean excerpt for a tag-only query', () => {
  const raw = '# 网关 #auto\n\nclean body only';
  const snip = side.noteSearchSnippet(raw, '#auto');
  assert.equal(snip, side.noteExcerpt(raw));
});
