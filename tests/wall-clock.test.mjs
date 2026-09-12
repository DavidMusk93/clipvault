/**
 * Capture-clock contract. One rewrite of timestamp and the user's timeline is gone.
 * Run via scripts/check-frontend.sh (listed in the gates comment + wall_clock_main.swift).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const db = src('DatabaseManager.swift');
const sync = src('CloudDocsSyncService.swift');
const policy = src('WallClockPolicy.swift');
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

test('this file and wall_clock_main.swift are in the deploy gate', () => {
  assert.match(check, /wall-clock\.test\.mjs/);
  assert.match(check, /wall-integrity\.test\.mjs/);
  assert.match(check, /wall_clock_main\.swift/);
  assert.match(check, /WallClockPolicy\.swift/);
});

test('WallClockPolicy is the only bump/OCR clock', () => {
  assert.match(policy, /enum WallClockPolicy/);
  assert.match(policy, /kind == "touch"/);
  assert.match(policy, /static func wallTsForDerivedOp/);
  assert.match(policy, /static func shouldRestoreToFirstSeen/);
  assert.match(sync, /WallClockPolicy\.bumpTimestamp\(forKind: op\.kind\)/);
  assert.match(sync, /WallClockPolicy\.wallTsForDerivedOp\(captureTs: captureTs\)/);
  assert.match(sync, /ocr skip, no capture clock/);
});

test('replica upsert must not MAX timestamp', () => {
  assert.doesNotMatch(
    functionBody(db, 'refreshRemoteFields'),
    /timestamp = MAX\(timestamp/,
    'refreshRemoteFields MAX(timestamp) is the 2026-09-11 clump',
  );
  assert.match(db, /bumpTimestamp: Bool/);
  assert.match(functionBody(sync, 'applyOpLocked'), /bumpTimestamp: WallClockPolicy/);
});

test('OCR follow-up must not emit Date() as wall_ts', () => {
  const ocr = functionBody(sync, 'enqueueOCROp');
  assert.match(ocr, /captureTimestampLocked/);
  assert.match(ocr, /wallTsForDerivedOp/);
  assert.doesNotMatch(
    ocr,
    /makeOp\([\s\S]{0,200}item: nil[\s\S]{0,80}Date\(\)/,
    'makeOp(item:nil) defaulted wall_ts to Date() and moved 440 cards',
  );
});

test('startup restores copy_count=1 rows to first_seen_at', () => {
  assert.match(db, /restoreCaptureTimestampsIfNeeded/);
  assert.match(db, /wall\.restore_capture_ts_v1/);
  assert.match(db, /SET timestamp = first_seen_at/);
  assert.match(db, /COALESCE\(copy_count, 1\) = 1/);
});

test('live wall does not tail-cap the keyset walk', () => {
  assert.doesNotMatch(html, /CLIENT_CAP/);
  const fetchIdx = html.indexOf('async function fetchPage');
  assert.ok(fetchIdx >= 0);
  assert.doesNotMatch(html.slice(fetchIdx, fetchIdx + 4500), /applyCap\(/);
});

test('AGENTS.md states capture-clock as a hard product constraint', () => {
  assert.match(agents, /记忆不可丢/);
  assert.match(agents, /一次错误/);
  assert.match(agents, /墙序 = 捕获时间/);
  assert.match(agents, /wall_clock_main\.swift/);
  assert.match(agents, /wall-integrity\.test\.mjs/);
  assert.match(agents, /WallClockPolicy\.swift/);
  assert.match(agents, /禁止 MAX\(timestamp\)/);
  assert.match(agents, /禁止合成一张/);
});
