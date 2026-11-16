/**
 * Relevance-ranked search (`order=relevance`): bm25 + offset cursor.
 * Pinned float first, then pure relevance — no pinThenRecency re-sort, so
 * the single ORDER BY keeps offset pages consistent.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const db = readFileSync(join(root, 'Sources/ClipVault/Store/DatabaseManager.swift'), 'utf8');
const web = readFileSync(join(root, 'Sources/ClipVault/HTTP/WebServer.swift'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');

function fn(src, name) {
  const re = new RegExp(`func ${name}\\b`);
  const m = re.exec(src);
  assert.ok(m, `missing func ${name}`);
  const rest = src.slice(m.index + name.length);
  const nextFn = rest.search(/\n    (private |@discardableResult[\s\S]{0,40})?func /);
  const nextMark = rest.search(/\n    \/\/ MARK:/);
  let cut = rest.length;
  if (nextFn >= 0) cut = Math.min(cut, nextFn);
  if (nextMark >= 0) cut = Math.min(cut, nextMark);
  return src.slice(m.index, m.index + name.length + cut);
}

test('ClipCursor carries an offset variant for ranked paging', () => {
  assert.match(db, /var offset: Int\? = nil/);
  assert.match(db, /if parts\[0\] == "o", let n = Int\(parts\[1\]\)/);
  assert.match(db, /return "o:\\\(offset\)"/);
});

test('ranked FTS orders by pinned-then-bm25 and pages by OFFSET', () => {
  const body = fn(db, 'runSearchFTSRanked');
  assert.match(body, /listTailSQLAliased/);
  assert.match(body, /\(c\.pinned_at IS NOT NULL\) DESC, bm25\(clipboard_fts\)/);
  assert.match(body, /LIMIT \? OFFSET \?/);
  assert.doesNotMatch(body, /keysetSQL/);
});

test('fetchPage relevance path skips pinThenRecency and emits an offset cursor', () => {
  assert.match(db, /order: String\? = nil/);
  assert.match(db, /let ranked = \(order == "relevance"\) && hasQuery && !trashOnly/);
  assert.match(db, /runSearchFTSRanked\(db: db, match: match, offset: offset/);
  assert.match(db, /if hasQuery && !trashOnly && !ranked \{\s*items\.sort \{ Self\.pinThenRecency/);
  assert.match(db, /ClipCursor\(timestamp: 0, id: "", offset: \(cursor\?\.offset \?\? 0\) \+ pageLimit\)/);
});

test('like fallback honors offset for ranked short queries', () => {
  const body = fn(db, 'runSearchLike');
  assert.match(body, /offset: Int\? = nil/);
  // Columns are `c.`-qualified because the query LEFT JOINs clipboard_fts.
  assert.match(body, /\(c\.pinned_at IS NOT NULL\) DESC, c\.timestamp DESC, c\.id DESC LIMIT \? OFFSET \?/);
});

test('broad LIKE reaches archived page bodies (FTS html mirror)', () => {
  // Archived pages keep only a CAS pointer in the row; their body lives in FTS.
  // Never a LEFT JOIN on the FTS5 table: it shifts the tail columns' affinity
  // and the read dies with `datatype mismatch`.
  const body = fn(db, 'runSearchLike');
  assert.doesNotMatch(body, /LEFT JOIN clipboard_fts/);
  assert.ok(body.includes('c.id IN \\(Self.ftsHtmlMatchSQL)'), 'body must probe the FTS html mirror');
  assert.match(body, /let likeSlots = narrowFields \? 5 : 8/);
  // Never a correlated EXISTS: it re-scans the FTS body per row (~9.5 s vs 14 ms).
  assert.match(db, /ftsHtmlMatchSQL = "\(SELECT id FROM clipboard_fts/);
  assert.doesNotMatch(db, /EXISTS\(SELECT 1 FROM clipboard_fts/);
});

test('archive rows are re-indexed from CAS after an FTS rebuild', () => {
  assert.match(db, /repairArchiveFTS\(\)/);
  const body = fn(db, 'repairArchiveFTS');
  assert.match(body, /archive_html_sha IS NOT NULL/);
  assert.match(body, /IFNULL\(length\(f\.html_content\), 0\) <= 200/);
  assert.match(body, /readBlobFile\(hash: row\.sha\)/);
  // The plain backfill must call it, otherwise a rebuild stays silently lossy.
  assert.match(fn(db, 'backfillFTS'), /repairArchiveFTS\(\)/);
});

test('HTTP parses order; notes rail requests relevance', () => {
  assert.match(web, /name == "order"/);
  assert.match(web, /excludeType: excludeType, order: order/);
  assert.match(html, /type=note&limit=50&q=' \+ encodeURIComponent\(qRaw\) \+ '&order=relevance'/);
  assert.match(html, /'&q=' \+ encodeURIComponent\(notesState\.query\) \+ '&order=relevance'/);
});
