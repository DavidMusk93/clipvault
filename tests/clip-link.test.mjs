/**
 * Clip-link judgment layer string gates (no XCTest target).
 * Run via scripts/check-frontend.sh — that script does not glob; this file
 * must be listed there or deploy will not run these assertions.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const db = readFileSync(join(root, 'ClipFlow/DatabaseManager.swift'), 'utf8');
const web = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');
const sync = readFileSync(join(root, 'ClipFlow/CloudDocsSyncService.swift'), 'utf8');
const item = readFileSync(join(root, 'ClipFlow/ClipboardItem.swift'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

function sliceFrom(src, startNeedle, maxLen = 8000) {
  const start = src.indexOf(startNeedle);
  assert.ok(start >= 0, `missing ${startNeedle}`);
  return src.slice(start, start + maxLen);
}

function functionBody(src, name) {
  const re = new RegExp(`func ${name}\\b`);
  const m = re.exec(src);
  assert.ok(m, `missing func ${name}`);
  const start = m.index;
  const rest = src.slice(start + name.length);
  const nextFn = rest.search(/\n    (private |@discardableResult[\s\S]{0,40})?func /);
  const nextMark = rest.search(/\n    \/\/ MARK:/);
  let cut = rest.length;
  if (nextFn >= 0) cut = Math.min(cut, nextFn);
  if (nextMark >= 0) cut = Math.min(cut, nextMark);
  return src.slice(start, start + name.length + cut);
}

test('clip_link is a judgment kind with recordLocal + replay + non-default cursor', () => {
  assert.match(sync, /case "clip_link"/);
  assert.match(sync, /func recordLocalClipLink\(/);
  assert.match(sync, /func replayDiskClipLinks\(/);
  assert.match(sync, /replayDiskClipLinks applied/);
  const idem = functionBody(sync, 'applyIsIdempotentSuccess');
  assert.match(idem, /"clip_link"/);
  assert.match(idem, /return false/);
  assert.doesNotMatch(idem, /default:\s*return true[\s\S]*clip_link/);
});

test('applySyncClipLinkLocked five-step order: from check before INSERT OR IGNORE', () => {
  const apply = sliceFrom(db, 'func applySyncClipLinkLocked');
  const fromCheck = apply.indexOf('fetchItemByIdLocked');
  const insert = apply.indexOf('INSERT OR IGNORE');
  assert.ok(fromCheck >= 0, 'apply must fetchItemByIdLocked for from');
  assert.ok(insert >= 0, 'apply path must mention INSERT OR IGNORE');
  assert.ok(fromCheck < insert, 'missing from must be checked before INSERT OR IGNORE');
  assert.match(apply, /clip_link quarantine/);
  assert.match(apply, /clip_link apply failed/);
  assert.match(apply, /return false/);
  assert.match(apply, /foldPairKeyIntoLinks/);
  assert.match(apply, /touchLinkCountsForItem/);
});

test('fold is latest-op not single-op LWW; replay insert-all then fold', () => {
  assert.match(db, /func foldPairKeyIntoLinks/);
  assert.match(db, /ORDER BY ts DESC, id DESC/);
  const fold = functionBody(db, 'foldPairKeyIntoLinks');
  assert.match(fold, /ORDER BY ts DESC/);
  assert.match(fold, /INSERT OR REPLACE INTO clip_links/);
  assert.match(db, /DELETE FROM clip_links WHERE pair_key/);
  const replay = functionBody(sync, 'replayDiskClipLinks');
  assert.match(replay, /ingestClipLinkReplayLocked/);
  assert.match(replay, /finishClipLinkReplayLocked/);
  assert.match(replay, /kind == "clip_link"/);
});

test('schema + listTailSQL + five SELECT sites keep link_count last', () => {
  assert.match(db, /CREATE TABLE IF NOT EXISTS clip_link_ops/);
  assert.match(db, /CREATE TABLE IF NOT EXISTS clip_links/);
  assert.match(db, /ADD COLUMN link_count INTEGER NOT NULL DEFAULT 0/);
  assert.match(db, /static let listTailSQL/);
  assert.match(db, /COALESCE\(c\.link_count, 0\)/);
  assert.match(db, /colCount >= 20/);
  for (const name of ['runSearchFTS', 'runSearchLike', 'runList', 'runPinned', 'fetchItemByIdLocked']) {
    const body = functionBody(db, name);
    assert.match(body, /listTailSQL/, `${name} must use listTailSQL / listTailSQLAliased`);
  }
  const fts = functionBody(db, 'runSearchFTS');
  assert.match(fts, /listTailSQLAliased/);
});

test('HTTP write API + GET links; POST does not SSE update', () => {
  assert.match(web, /POST \/api\/clips\/link/);
  assert.match(web, /pathOnly == "\/api\/clips\/link"/);
  assert.match(web, /\/api\/items\/.*\/links/);
  assert.match(web, /func handleClipLink/);
  assert.match(web, /func sendItemLinks/);
  assert.match(web, /dict\["linkCount"\] = item\.linkCount/);
  const handle = functionBody(web, 'handleClipLink');
  assert.match(handle, /recordLocalClipLink/);
  assert.doesNotMatch(handle, /broadcastSSE/);
  assert.match(web, /笔记侧关联下期开放|submitClipLink/);
});

test('ClipboardItem carries linkCount; pair_key + cap 32', () => {
  assert.match(item, /let linkCount: Int/);
  assert.match(db, /func makePairKey/);
  assert.match(db, /clipLinkDegreeCap = 32/);
  assert.match(db, /最多 32 条关联/);
  assert.match(db, /hh:/);
  assert.match(db, /nh:/);
  assert.match(db, /nn:/);
});

test('dedupe protects clip_links / clip_link_ops', () => {
  const dedupe = functionBody(db, 'dedupeStaleBatch');
  assert.match(dedupe, /clip_links/);
  assert.match(dedupe, /clip_link_ops/);
});

test('touchLinkCounts hooks insert/bump/upsert/compose/tombstone', () => {
  assert.match(db, /func touchLinkCountsForItem/);
  const insert = functionBody(db, 'insertNewItem');
  const bump = functionBody(db, 'bumpLatestAlive');
  const tomb = functionBody(db, 'applySyncTombstoneLocked');
  const compose = functionBody(db, 'saveComposeNoteLocked');
  const applyCompose = functionBody(db, 'applySyncComposeLocked');
  assert.match(insert, /touchLinkCountsForItem/);
  assert.match(bump, /touchLinkCountsForItem/);
  assert.match(tomb, /touchLinkCountsForItem/);
  assert.match(compose, /touchLinkCountsForItem/);
  assert.match(applyCompose, /touchLinkCountsForItem/);
});

test('web link UI: popover, same-slot button, no wall reset', () => {
  const html = readFileSync(join(root, 'web/index.html'), 'utf8');
  assert.match(html, /id="linkToast"/);
  assert.match(html, /data-link=/);
  assert.match(html, /function openLinkToast/);
  assert.match(html, /function patchCardLinkState/);
  assert.match(html, /positionAnchoredCard/);
  const j = html.indexOf('async function jumpToLocator');
  const end = html.indexOf('async function applyAppHash', j);
  const jump = html.slice(j, end > j ? end : j + 2000);
  assert.doesNotMatch(jump, /fetchPage\(\{\s*reset:\s*true/);
  const taste = readFileSync(join(root, 'docs/design-taste.md'), 'utf8');
  assert.match(taste, /关联入口/);
  assert.match(taste, /落地信标/);
  assert.match(html, /function flashCard/);
  assert.match(html, /scale\(1\.02\)/);
  assert.doesNotMatch(
    html.slice(html.indexOf('.m3-card.is-flash'), html.indexOf('.m3-card.is-flash') + 500),
    /translateY/,
  );
});

test('AGENTS.md requires recordLocalClipLink; check-frontend lists this file', () => {
  assert.match(agents, /recordLocalClipLink/);
  assert.match(agents, /clip_link/);
  assert.match(agents, /硬编码/);
  assert.doesNotMatch(
    agents.split('### 前端部署门禁')[1]?.slice(0, 800) ?? '',
    /或: node --test tests\/\*\.test\.mjs/,
  );
  assert.match(check, /tests\/clip-link\.test\.mjs/);
  assert.doesNotMatch(check, /node --test tests\/\*\.test\.mjs/);
});
