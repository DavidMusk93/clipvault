/**
 * Note title vs body H1.
 *
 * Storage is "# title\n\nbody" (ComposeNotes.normalizedBody). The title field is
 * the only thing that names a note: a leading H1 that differs from the typed title
 * is body content, so it must stay in the body and the typed title must win.
 * Adopting it replaces the user's title with a heading and eats the heading out of
 * the body — the 2026-10-13 regression, where title "sgtt frontier upgrade" became
 * "jiu" (compose_ops for item 9871EDDE-F014-4EEE-AD37-1EF79D072D3F).
 *
 * The pure helpers are the shipped inline ones, extracted from web/index.html, so
 * this cannot drift from what the browser runs.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const swift = readFileSync(join(root, 'Sources/ClipVault/Store/ComposeNotes.swift'), 'utf8');

/** Slice `function <name>(...) {...}` out of the inline script. */
function fnSource(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} missing in web/index.html`);
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

function build(names) {
  const body = names.map((n) => fnSource(html, n)).join('\n');
  return new Function(`${body}\nreturn { ${names.join(', ')} };`)();
}

const notes = build([
  'escapeRegExp',
  'noteExcerpt',
  'decodeNoteBody',
  'noteTitleText',
  'noteTitleOf',
  'noteStripTitle',
  'noteSaveResolution',
]);

test('a stored note is "# title" + body; only the leading H1 is the title', () => {
  const stored = '# 甲\n\n# 乙\n\n旧的';
  assert.equal(notes.noteTitleText(stored), '甲');
  assert.equal(notes.noteTitleOf({ textContent: stored }), '甲');
  assert.equal(notes.noteStripTitle(stored, '甲'), '# 乙\n\n旧的');
});

test('a body H1 never replaces the title the user typed', () => {
  const r = notes.noteSaveResolution('# jiu\n\n旧的', 'sgtt frontier upgrade', false, false);
  assert.equal(r.title, 'sgtt frontier upgrade');
  assert.equal(r.body, '# jiu\n\n旧的', 'the heading stays in the body');
  assert.equal(r.adoptTitle, false);
});

test('a stored leading H1 equal to the typed title is the title, not body copy', () => {
  const r = notes.noteSaveResolution('# 甲\n\nbody', '甲', false, false);
  assert.equal(r.title, '甲');
  assert.equal(r.body, 'body');
  assert.equal(r.adoptTitle, true);
});

test('a plain stored body with a typed title is left alone', () => {
  const r = notes.noteSaveResolution('body only', '甲', false, false);
  assert.equal(r.title, '甲');
  assert.equal(r.body, 'body only');
  assert.equal(r.adoptTitle, false);
});

test('merge/conflict is server-authoritative: adopt the stored title', () => {
  for (const [merged, conflict] of [[true, false], [false, true], [true, true]]) {
    const r = notes.noteSaveResolution('# 乙\n\nx', '甲', merged, conflict);
    assert.equal(r.title, '乙');
    assert.equal(r.body, 'x');
    assert.equal(r.adoptTitle, true);
  }
});

test('an empty title field keeps the first-H1 convention', () => {
  const r = notes.noteSaveResolution('# jiu\n\n旧的', '', false, false);
  assert.equal(r.title, 'jiu');
  assert.equal(r.body, '旧的');
  assert.equal(r.adoptTitle, true);
});

test('the autosave path resolves the title instead of adopting noteTitleOf raw', () => {
  assert.match(html, /noteSaveResolution\(stored, title, j\.merged, j\.conflict\)/);
  const save = html.slice(html.indexOf('async function saveNoteNow()'));
  const block = save.slice(0, save.indexOf('paintNotesMergeHint'));
  assert.doesNotMatch(block, /titleEl\.value = t;/, 'no raw H1 adoption in autosave');
});

test('the server keeps an explicit title when the body starts with another H1', () => {
  assert.match(swift, /if leadingHeading\(b\) == t \{ return b \}/);
  assert.doesNotMatch(swift, /if b\.hasPrefix\("# "\) \{ return b \}/);
  assert.match(swift, /static func leadingHeading\(_ body: String\) -> String\?/);
});
