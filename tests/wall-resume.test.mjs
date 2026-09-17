/**
 * Wall resume affordance — reader_state checkpoint surfaced on the archived card.
 * Run: node --test tests/wall-resume.test.mjs
 *
 * Contract: the archive View persists scroll_checkpoint into reader_state; the
 * wall reuses the single「查看」slot as「继续 N%」for 3%–96%, and never on trash.
 * One button, one slot — mirrors the 分享 / 取消分享 rule in design-taste.md.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { src } from './helpers/src.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const swiftWeb = src('WebServer.swift');
const swiftDb = src('DatabaseManager.swift');

/** Pull one `function name(...) { ... }` out of the inline script (brace-matched). */
function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in index.html`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`${name} has unbalanced braces`);
}

test('itemReadProgress: resume only for 3%–96%, never trash and never empty', () => {
  const fnSrc = extractFunction(html, 'itemReadProgress');
  const clips = [
    { id: 'a', read: { pct: 42, heading: '第二章' } },
    { id: 'b', read: { pct: 2 } },
    { id: 'c', read: { pct: 97 } },
    { id: 'd', inTrash: true, read: { pct: 50 } },
    { id: 'e', deletedAt: 123, read: { pct: 50 } },
    { id: 'f' },
    { id: 'g', read: { quote: '一段摘录' } },
  ];
  const fn = new Function('clips', `${fnSrc}; return itemReadProgress;`)(clips);

  assert.equal(fn('a').pct, 42, 'mid-article resumes');
  assert.equal(fn('a').label, '第二章', 'chapter hint rides along');
  assert.equal(fn('b'), null, 'a peek at 2% is not a resume');
  assert.equal(fn('c'), null, '97% is effectively finished');
  assert.equal(fn('d'), null, 'trash rows never advertise a position');
  assert.equal(fn('e'), null, 'soft-deleted rows never advertise a position');
  assert.equal(fn('f'), null, 'no reader_state → plain 查看');
  assert.equal(fn('g'), null, 'missing pct → plain 查看');
  assert.equal(fn(''), null, 'empty id → plain 查看');
});

test('toolbar reuses the single 查看 slot as 继续 N% (no second button)', () => {
  assert.match(html, /继续 \$\{pct\}|继续 ' \+ resume\.pct \+ '%/, 'label morphs by progress');
  assert.match(html, /play_circle/, 'resume icon');
  assert.match(html, /data-view-archive="\$\{escAttr\(itemId\)\}"/, 'same archive-view slot');
  assert.match(html, /itemReadProgress\(itemId\)/, 'toolbar consults progress');
});

test('closing the View refreshes the card once the checkpoint lands', () => {
  assert.match(html, /archiveReaderItemId = item\.id/, 'View remembers which card it opened');
  assert.match(html, /refreshClipInPlace\(itemId\), 400\)/, 'post-pagehide refresh');
});

test('wall API ships read progress on page, id and ids paths', () => {
  assert.match(swiftWeb, /read: \[String: Any\]\? = nil/, 'itemToJSON accepts read');
  assert.match(swiftWeb, /if let read, item\.deletedAt == nil \{ dict\["read"\] = read \}/, 'never attach read to trash');
  const calls = swiftWeb.match(/readerProgressMap\(ids:/g) || [];
  assert.ok(calls.length >= 3, `expected page + id + ids paths, saw ${calls.length}`);
});

test('readerProgressMap reads reader_state in one query and clamps the band', () => {
  assert.match(swiftDb, /func readerProgressMap\(ids: \[UUID\]\)/, 'batched lookup exists');
  assert.match(swiftDb, /reader_state FROM clipboard_items WHERE id IN/, 'single IN(...) query, no N+1');
  assert.match(swiftDb, /guard pct >= 3, pct <= 96 else \{ continue \}/, 'same 3%–96% band as the client');
});
