/**
 * Product-loss gate. One wrong clock, cap, chip, hydrate, or masonry
 * collapse and the user sees "history gone".
 * Run via scripts/check-frontend.sh (listed in the gates comment).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const db = src('DatabaseManager.swift');
const web = src('WebServer.swift');
const sync = src('CloudDocsSyncService.swift');
const backup = src('CloudDocsBackupService.swift');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

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

function htmlFn(name) {
  const re = new RegExp(`function ${name}\\b`);
  const m = re.exec(html);
  assert.ok(m, `missing function ${name}`);
  const start = m.index;
  const rest = html.slice(start);
  const next = rest.slice(1).search(/\n    function /);
  return next >= 0 ? rest.slice(0, next + 1) : rest.slice(0, 4000);
}

test('this file and wall-clock gates are in check-frontend.sh', () => {
  assert.match(check, /wall-integrity\.test\.mjs/);
  assert.match(check, /wall-clock\.test\.mjs/);
  assert.match(check, /wall_clock_main\.swift/);
  assert.match(check, /WallClockPolicy\.swift/);
});

test('AGENTS.md states the six product-loss modes as hard law', () => {
  assert.match(agents, /记忆不可丢/);
  assert.match(agents, /一次错误/);
  assert.match(agents, /墙序 = 捕获时间/);
  assert.match(agents, /禁止 MAX\(timestamp\)/);
  assert.match(agents, /CLIENT_CAP/);
  assert.match(agents, /clientFilter/);
  assert.match(agents, /hydrateBlob/);
  assert.match(agents, /Documents/);
  assert.match(agents, /禁止合成一张/);
  assert.match(agents, /历史只剩 Stop 结论/);
  assert.match(agents, /wall-integrity\.test\.mjs/);
  assert.match(agents, /WallClockPolicy\.swift/);
  assert.match(agents, /fetchPage\(\{reset:true\}\)/);
  assert.match(agents, /IN \('html','rtf'\)/);
});

test('type chips refetch the keyset with type=, not only the in-memory 30', () => {
  const apply = htmlFn('applyWallQueryParams');
  assert.match(apply, /params\.set\('type', currentFilter\)/);
  const chips = html.slice(html.indexOf('// Filters + library/trash view'), html.indexOf('// Server-side search'));
  assert.match(chips, /prevFilter !== currentFilter \|\| prevView !== currentView/);
  assert.match(chips, /fetchPage\(\{\s*reset:\s*true\s*\}\)/);
  assert.match(db, /IN \('html', 'rtf'\)/);
  const pred = functionBody(db, 'typePredicateSQL');
  assert.match(pred, /typeFilter == "html"/);
  assert.match(pred, /IN \('html', 'rtf'\)/);
});

test('live wall does not tail-cap the keyset walk', () => {
  assert.doesNotMatch(html, /CLIENT_CAP/);
  const fetch = htmlFn('fetchPage');
  assert.doesNotMatch(fetch, /applyCap\(/);
  assert.doesNotMatch(html, /clips\.splice\(/);
});

test('wall image bytes hydrate the same CAS replicas as archive', () => {
  const load = functionBody(web, 'loadClipImageBytes');
  assert.match(load, /hydrateBlob\(raw\)/);
  assert.match(load, /readBlobFile/);
  assert.match(db, /func materializeBlobsIfSymlinked/);
  assert.match(db, /LaunchAgent \+ TCC cannot read historical CAS through a Documents symlink/);
  const blobs = functionBody(backup, 'syncBlobsToCAS');
  assert.match(blobs, /local CAS unlistable/);
  assert.match(blobs, /throw NSError/);
  assert.match(backup, /throws -> CASSyncResult/);
});

test('masonry must not collapse into one occupied column', () => {
  assert.match(html, /function healMasonryIfDegenerate/);
  assert.match(html, /function masonryIsDegenerate/);
  assert.match(html, /masonryOccupiedCols/);
  const pack = htmlFn('packMasonry');
  assert.match(pack, /used\.size < 2/);
  assert.match(pack, /i % cols/);
  const prepend = htmlFn('prependCardsIncremental');
  assert.match(prepend, /healMasonryIfDegenerate\(host\)/);
});

test('440-image peer clump stays 440 cards on a capture-time keyset', () => {
  const rows = [];
  for (let i = 0; i < 20; i++) rows.push({ id: `T1-${String(i).padStart(3, '0')}`, ts: 3000 - i * 0.01, type: 'text' });
  const clump = 2000;
  for (let i = 0; i < 440; i++) rows.push({ id: `IMG-${String(i).padStart(3, '0')}`, ts: clump + i * 0.00047, type: 'image' });
  for (let i = 0; i < 50; i++) rows.push({ id: `T0-${String(i).padStart(3, '0')}`, ts: 500 - i, type: 'text' });
  for (let i = 0; i < 5; i++) rows.push({ id: `RTF-${i}`, ts: 2900 - i, type: 'rtf' });

  const desc = (a, b) => (b.ts - a.ts) || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0);
  function page(cursor, limit, type) {
    const rest = [...rows]
      .sort(desc)
      .filter((r) => {
        if (type === 'html') {
          if (r.type !== 'html' && r.type !== 'rtf') return false;
        } else if (type && r.type !== type) return false;
        if (!cursor) return true;
        return r.ts < cursor.ts || (r.ts === cursor.ts && r.id < cursor.id);
      });
    return rest.slice(0, limit);
  }
  function walk(type) {
    let cursor = null;
    const seen = [];
    for (let i = 0; i < 80; i++) {
      const batch = page(cursor, 30, type);
      if (!batch.length) break;
      seen.push(...batch);
      const last = batch[batch.length - 1];
      cursor = { ts: last.ts, id: last.id };
    }
    return seen;
  }

  const all = walk(null);
  assert.equal(all.filter((r) => r.type === 'image').length, 440, 'clump is 440 cards, not one');
  assert.equal(all.filter((r) => r.id.startsWith('T0-')).length, 50, 'keyset must reach older text');
  assert.equal(new Set(rows.filter((r) => r.type === 'image').map((r) => Math.trunc(r.ts))).size, 1);

  const page1Text = page(null, 30, null).filter((r) => r.type === 'text' && r.id.startsWith('T0-'));
  assert.equal(page1Text.length, 0, 'clientFilter of page1 hides T0 — that is the 滤错 bug');

  const texts = walk('text');
  assert.equal(texts.filter((r) => r.type === 'image').length, 0);
  assert.equal(texts.filter((r) => r.id.startsWith('T0-')).length, 50, 'type=text keyset walks past the clump');
  assert.equal(texts.filter((r) => r.id.startsWith('T1-')).length, 20);

  const htmlChip = walk('html');
  assert.equal(htmlChip.filter((r) => r.type === 'rtf').length, 5, 'html chip includes rtf');

  let window = [];
  let cursor = null;
  for (let i = 0; i < 80; i++) {
    const batch = page(cursor, 30, null);
    if (!batch.length) break;
    window = window.concat(batch);
    if (window.length > 300) window = window.slice(0, 300);
    const last = batch[batch.length - 1];
    cursor = { ts: last.ts, id: last.id };
  }
  assert.equal(
    window.filter((r) => r.id.startsWith('T0-')).length,
    0,
    'CLIENT_CAP=300 is the 砍尾 bug: T0 never stays',
  );
});

test('OCR / replica must not rewrite capture timestamp', () => {
  assert.match(sync, /WallClockPolicy\.bumpTimestamp\(forKind: op\.kind\)/);
  assert.match(sync, /WallClockPolicy\.wallTsForDerivedOp\(captureTs: captureTs\)/);
  assert.doesNotMatch(
    functionBody(db, 'refreshRemoteFields'),
    /timestamp = MAX\(timestamp/,
  );
  const ocr = functionBody(sync, 'enqueueOCROp');
  assert.doesNotMatch(ocr, /makeOp\([\s\S]{0,200}item: nil[\s\S]{0,80}Date\(\)/);
});
