/**
 * Search must hit user-authored comments (eval notes + View reader comments).
 * Run via scripts/check-frontend.sh — that script does not glob.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const db = readFileSync(join(root, 'ClipFlow/DatabaseManager.swift'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');
const indexHtml = readFileSync(join(root, 'web/index.html'), 'utf8');

function sliceFrom(src, startNeedle, maxLen = 8000) {
  const start = src.indexOf(startNeedle);
  assert.ok(start >= 0, `missing ${startNeedle}`);
  return src.slice(start, start + maxLen);
}

test('this file is in the deploy frontend gate', () => {
  assert.match(check, /search-judgment\.test\.mjs/);
});

test('FTS schema includes judgment_text and rebuilds on version bump', () => {
  assert.match(db, /ftsSchemaVersion = "judgment_v1"/);
  assert.match(db, /ADD COLUMN judgment_text TEXT/);
  const fts = sliceFrom(db, 'CREATE VIRTUAL TABLE clipboard_fts USING fts5', 500);
  assert.match(fts, /judgment_text/);
  assert.match(db, /storedSchema != Self\.ftsSchemaVersion/);
  assert.match(db, /func assembleJudgmentTextLocked/);
  assert.match(db, /func refreshJudgmentTextLocked/);
});

test('reader comment and eval note refresh FTS; LIKE does not scan payload JSON', () => {
  const append = sliceFrom(db, 'func appendReaderOpLocked', 12000);
  assert.match(append, /kind != "scroll_checkpoint" \{\s*refreshJudgmentTextLocked/);
  assert.match(append, /reindexFTSRowLocked/);
  assert.match(db, /refreshJudgmentTextLocked\(idStr\)\s*reindexFTSRowLocked\(idStr\)\s*guard let item = fetchItemByIdLocked/);
  const like = sliceFrom(db, 'func runSearchLike', 1800);
  assert.match(like, /judgment_text/);
  assert.doesNotMatch(like, /reader_ops\.payload/);
  const assemble = sliceFrom(db, 'func assembleJudgmentTextLocked', 2500);
  assert.match(assemble, /user_evaluations/);
  assert.match(assemble, /reader_ops/);
  assert.match(assemble, /"comment"/);
});

test('wall search placeholder mentions comments', () => {
  assert.match(indexHtml, /id="searchInput"[^>]*placeholder="[^"]*评论/);
});
