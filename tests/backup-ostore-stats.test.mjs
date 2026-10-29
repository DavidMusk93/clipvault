/**
 * ClipVault ostore 远程冷备统计契约。
 * 回归：面板必须显示本轮/远端/上次运行统计，且重启后不清零。
 * Run via scripts/check-frontend.sh — that script does not glob.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const ostore = src('OstoreBackup.swift');
const indexHtml = readFileSync(join(root, 'web/index.html'), 'utf8');
const doc = readFileSync(join(root, 'docs/ostore-backup.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

function sliceFrom(text, startNeedle, maxLen = 4000) {
  const start = text.indexOf(startNeedle);
  assert.ok(start >= 0, `missing ${startNeedle}`);
  return text.slice(start, start + maxLen);
}

test('this file is in the deploy frontend gate', () => {
  assert.match(check, /backup-ostore-stats\.test\.mjs/);
});

test('status carries run statistics, not just a phase', () => {
  const status = sliceFrom(ostore, 'struct Status: Codable', 1600);
  for (const field of [
    'var total = 0',
    'var uploaded = 0',
    'var skipped = 0',
    'var failed = 0',
    'var pending = 0',
    'var uploadedBytes = 0',
    'var skippedBytes = 0',
    'var manifestObjects = 0',
    'var manifestBytes = 0',
    'var remoteObjects = 0',
    'var remoteBytes = 0',
    'var startedUnix: Double? = nil',
    'var durationSeconds: Double? = nil',
    'var lastRun: Run? = nil'
  ]) {
    assert.ok(status.includes(field), `Status missing ${field}`);
  }
  const run = sliceFrom(ostore, 'struct Run: Codable', 600);
  assert.match(run, /var finishedUnix: Double\? = nil/);
  assert.match(run, /var error: String\? = nil/);
});

test('pending is derived so an aborted run shows 未完成 instead of a silent gap', () => {
  assert.match(ostore, /result\.pending = max\(0, result\.total - result\.uploaded - result\.skipped - result\.failed\)/);
});

test('byte counters come from real file sizes, remote totals from a listing', () => {
  assert.match(ostore, /private func fileSize\(_ url: URL\) -> Int/);
  assert.match(ostore, /bump \{ \$0\.skipped \+= 1; \$0\.skippedBytes \+= size \}/);
  assert.match(ostore, /bump \{ \$0\.uploaded \+= 1; \$0\.uploadedBytes \+= size \}/);
  assert.match(ostore, /remoteTotals = \(files\.count/);
});

test('last run + last success survive a restart (state file, 0600)', () => {
  assert.match(ostore, /ostore-backup\.state\.json/);
  assert.match(ostore, /private func finish\(ok: Bool, started: Double, error: String\?, remote: \(objects: Int, bytes: Int\)\?\)/);
  assert.match(ostore, /\.posixPermissions: 0o600/);
  const restore = sliceFrom(ostore, 'private init()', 900);
  assert.match(restore, /state\.lastRun = saved\.lastRun/);
  assert.match(restore, /state\.lastSuccessUnix = saved\.lastSuccessUnix/);
});

test('progress pings are coalesced so a long upload still updates the panel', () => {
  const bump = sliceFrom(ostore, 'private func bump(', 700);
  assert.match(bump, /now - lastPing >= pingInterval/);
  assert.match(ostore, /private let pingInterval: Double = 2/);
  assert.match(bump, /NotificationCenter\.default\.post\(name: CloudDocsBackupService\.statusChangedNotification/);
});

test('panel renders the ostore statistics block', () => {
  assert.match(indexHtml, /id="bkOstoreStats"/);
  assert.match(indexHtml, /function paintOstoreStats\(os\)/);
  assert.match(indexHtml, /paintOstoreStats\(os\);/);
  const paint = sliceFrom(indexHtml, 'function paintOstoreStats(os)', 3000);
  for (const label of ['本轮对象', '本轮字节', '耗时', '本地清单', '远端对象', '上次运行']) {
    assert.ok(paint.includes(label), `paintOstoreStats missing ${label}`);
  }
  assert.match(paint, /未完成 ' \+ fmtCount\(n\(os\.pending\)\)/);
  assert.match(paint, /os\.lastRun/);
  // The old single-line summary must not repeat the counters — one source of truth.
  const status = sliceFrom(indexHtml, 'const osLabel = document.getElementById', 700);
  assert.ok(!/上传 ' \+ \(os\?\.uploaded/.test(status), 'counters must live in the stats block');
});

test('doc names the state file and the statistics fields', () => {
  assert.match(doc, /config\/ostore-backup\.state\.json/);
  assert.match(doc, /`remoteObjects` \/ `remoteBytes`/);
  assert.match(doc, /每 2 秒最多广播一次/);
});

// ---- DOM path: actually run paintOstoreStats against a jsdom panel ----
// jsdom is a dev-only dependency (npm ci). Skip cleanly when absent so
// scripts/check-frontend.sh still passes without an npm install.
let jsdomWindow = null;
let domSkip = false;
try {
  const { JSDOM } = await import('jsdom');
  jsdomWindow = new JSDOM('<!doctype html><html><body><div id="bkOstoreStats"></div></body></html>').window;
} catch {
  domSkip = 'jsdom not installed — run `npm ci`';
}

function loadPaint() {
  const html = indexHtml;
  const start = html.indexOf('function fmtBytes(n) {');
  const end = html.indexOf('async function refreshBackupStatus(');
  assert.ok(start >= 0 && end > start, 'cannot slice the ostore stats helpers');
  const snippet = html.slice(start, end);
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const formatLocalTime = (v) => (v == null ? '—' : 'T' + Math.round(Number(v)));
  return new Function('document', 'esc', 'formatLocalTime', `${snippet}\nreturn paintOstoreStats;`)(
    jsdomWindow.document, esc, formatLocalTime
  );
}

test('paintOstoreStats renders counts, bytes, remote totals and the last run', { skip: domSkip }, () => {
  const paint = loadPaint();
  const host = jsdomWindow.document.getElementById('bkOstoreStats');
  paint({
    configured: true, inProgress: false, phase: 'ok',
    total: 1506, uploaded: 1, skipped: 1503, failed: 0, pending: 2,
    uploadedBytes: 107450368, skippedBytes: 8900000000,
    manifestObjects: 1503, manifestBytes: 8900000000,
    remoteObjects: 1504, remoteBytes: 8950000000,
    startedUnix: 1793260000, durationSeconds: 62.4,
    lastSuccessUnix: 1793260062.4,
    lastRun: { phase: 'ok', uploaded: 1, skipped: 1503, failed: 0, durationSeconds: 62.4, finishedUnix: 1793260062.4 }
  });
  const text = host.textContent;
  assert.match(text, /本轮对象/);
  assert.match(text, /上传 1 · 跳过 1,503 · 未完成 2 \/ 共 1,506/);
  assert.match(text, /102\.47 MB 上传/);
  assert.match(text, /本地清单/);
  assert.match(text, /1,503 对象/);
  assert.match(text, /远端对象/);
  assert.match(text, /1,504 对象/);
  assert.match(text, /耗时/);
  assert.match(text, /62\.4 s/);
  assert.match(text, /上次运行/);
  assert.match(text, /成功 · 上传 1 · 跳过 1,503 · 62\.4 s/);
});

test('paintOstoreStats keeps last-run stats after a restart (live counters zeroed)', { skip: domSkip }, () => {
  const paint = loadPaint();
  const host = jsdomWindow.document.getElementById('bkOstoreStats');
  paint({
    configured: true, inProgress: false, phase: 'ok',
    total: 0, uploaded: 0, skipped: 0, failed: 0, pending: 0,
    uploadedBytes: 0, skippedBytes: 0,
    manifestObjects: 0, manifestBytes: 0,
    remoteObjects: 1504, remoteBytes: 8950000000,
    durationSeconds: 61.2,
    lastRun: { phase: 'ok', uploaded: 2, skipped: 1501, failed: 0, durationSeconds: 61.2, finishedUnix: 1793260062.4 }
  });
  const text = host.textContent;
  assert.doesNotMatch(text, /本轮对象/);
  assert.match(text, /远端对象/);
  assert.match(text, /上次运行/);
  assert.match(text, /上传 2 · 跳过 1,501/);
});

test('paintOstoreStats tells the user what to configure, never a fake zero', { skip: domSkip }, () => {
  const paint = loadPaint();
  const host = jsdomWindow.document.getElementById('bkOstoreStats');
  paint({ configured: false });
  assert.match(host.textContent, /未配置/);
  assert.match(host.textContent, /config\/ostore-backup\.json/);
  assert.doesNotMatch(host.textContent, /本轮对象/);
});
