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
  const paint = sliceFrom(indexHtml, 'function paintOstoreStats(os)', 6000);
  for (const label of ['本轮对象', '本轮字节', '耗时', '本地清单', '远端对象', '上次运行']) {
    assert.ok(paint.includes(label), `paintOstoreStats missing ${label}`);
  }
  assert.match(paint, /未完成 ' \+ fmtCount\(n\(os\.pending\)\)/);
  assert.match(paint, /os\.lastRun/);
  // Counters live only in the stats block; the row's status line stays prose.
  const row = sliceFrom(indexHtml, 'function ostoreRow(os)', 2600);
  assert.ok(!/上传 ' \+ \(os\?\.uploaded/.test(row), 'counters must live in the stats block');
  assert.match(row, /id="bkOstoreStatus"/);
});

test('doc records the unified panel shape (four sources, one switch contract)', () => {
  assert.match(doc, /## 面板形态（统一，不是特例）/);
  assert.match(doc, /四行同一套结构/);
  assert.match(doc, /`POST \/api\/backup\/config \{"ostoreEnabled":bool\}`/);
  assert.match(doc, /`enabled` 缺省为 `true`/);
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

test('ostore chart selection explains actual counts and survives a refresh', { skip: domSkip }, () => {
  const paint = loadPaint();
  const host = jsdomWindow.document.getElementById('bkOstoreStats');
  const status = { configured:true, inProgress:true, total:10, uploaded:2, skipped:6, failed:1, pending:1 };
  paint(status);
  host.querySelector('[data-backup-segment="skipped"]').click();
  assert.match(host.querySelector('.backup-chart-detail').textContent, /远端已有相同内容的对象：6 \/ 10（60\.0%）/);
  assert.equal(host.querySelector('[data-backup-segment="skipped"]').getAttribute('aria-pressed'), 'true');
  paint(status);
  assert.equal(host.querySelector('[data-backup-segment="skipped"]').getAttribute('aria-pressed'), 'true');
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

test('ostore is the fourth backup source: same pill + same switch, no bespoke button', () => {
  // No bespoke action button anywhere: the row is rendered from the same shape as
  // iCloud / Google Drive / 夸克 (title + pill, path, 上次/phase, right-hand switch).
  assert.doesNotMatch(indexHtml, /id="bkOstoreRun"/);
  assert.doesNotMatch(indexHtml, /\.backup-pill\b/);
  assert.match(indexHtml, /destHost\.appendChild\(ostoreRow\(os\)\)/);
  assert.match(indexHtml, /paintOstoreStats\(os\);/);
  const row = sliceFrom(indexHtml, 'function ostoreRow(os)', 2600);
  assert.match(row, /row\.className = 'backup-row'/);
  assert.match(row, /<span class="pill (bad|warn|ok)">/);
  assert.match(row, /<label class="switch" title="启用 ostore 远程冷备">/);
  assert.match(row, /input type="checkbox" data-ostore="1"/);
  assert.match(row, /esc\(os\?\.baseURL \|\| '—'\)/);
  // The switch is the same contract as the cloud destinations: POST config.
  assert.match(row, /JSON\.stringify\(\{ ostoreEnabled: on \}\)/);
  assert.match(row, /\/api\/backup\/config/);
  // Queued state still reads out, now on the status line it belongs to.
  assert.match(row, /os\?\.queued \? ' · 已排队下一轮' : ''/);
});

test('the switch is backed by the ostore config, not a UI-only toggle', () => {
  const status = sliceFrom(ostore, 'struct Status: Codable', 1900);
  assert.match(status, /var enabled = true/);
  assert.match(status, /var baseURL: String\? = nil/);
  assert.match(ostore, /private struct Config: Decodable \{ let baseURL: String; let token: String; let enabled: Bool\? \}/);
  assert.match(ostore, /result\.enabled = config\?\.enabled \?\? true/);
  assert.match(ostore, /result\.baseURL = config\?\.baseURL/);
  // Disabled must actually stop the mirror step, and a click while off must say so.
  assert.match(ostore, /guard let config = try\? loadConfig\(\), config\.enabled != false else \{ return false \}/);
  const setter = sliceFrom(ostore, 'func setEnabled\(_ on: Bool\) -> Bool', 1200);
  assert.match(setter, /obj\["enabled"\] = on/);
  assert.match(setter, /\.posixPermissions: 0o600/);
  const web = src('WebServer.swift');
  assert.match(web, /if let raw = json\["ostoreEnabled"\]/);
  assert.match(web, /OstoreBackup\.shared\.setEnabled\(on\)/);
  assert.match(web, /ostore 冷备已关闭（打开备份源处的开关）/);
});

test('unified row keeps the queued click honest and disables only when unconfigured', () => {
  const row = sliceFrom(indexHtml, 'function ostoreRow(os)', 2600);
  assert.match(row, /os\?\.configured \? '' : ' disabled'/);
  assert.doesNotMatch(row, /inProgress[^;]*disabled/);
});

// ---- DOM path: render the ostore row exactly as the panel does ----
function loadOstoreRow(fail = false) {
  const start = indexHtml.indexOf('function ostoreRow(os)');
  const end = indexHtml.indexOf('async function refreshBackupStatus(');
  assert.ok(start >= 0 && end > start, 'cannot slice ostoreRow');
  const snippet = indexHtml.slice(start, end);
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const formatLocalTime = (v) => (v == null ? '—' : 'T' + Math.round(Number(v)));
  const calls = [];
  const fakes = {
    document: jsdomWindow.document,
    esc,
    formatLocalTime,
    API: 'http://api.test',
    toast: (m) => calls.push({ toast: m }),
    refreshBackupStatus: () => calls.push({ refresh: true }),
    fetch: (url, opts) => { calls.push({ url, body: opts?.body }); return Promise.resolve({ ok: !fail, json: async () => fail ? ({ ok: false, message: '保存失败' }) : ({ ok: true }) }); }
  };
  const fn = new Function('document', 'esc', 'formatLocalTime', 'API', 'toast', 'refreshBackupStatus', 'fetch',
    `${snippet}\nreturn ostoreRow;`)(fakes.document, fakes.esc, fakes.formatLocalTime, fakes.API, fakes.toast, fakes.refreshBackupStatus, fakes.fetch);
  return { row: fn, calls };
}

test('ostoreRow renders a switch and writes config on toggle', { skip: domSkip }, async () => {
  const { row, calls } = loadOstoreRow();
  const el = row({ configured: true, enabled: true, baseURL: 'https://cc.example/clipvault-ostore', phase: 'ok', lastSuccessUnix: 1793262489, inProgress: false, queued: false });
  const input = el.querySelector('input[data-ostore]');
  assert.ok(input, 'switch input missing');
  assert.equal(input.checked, true);
  assert.equal(input.disabled, false);
  assert.match(el.textContent, /ostore 远程冷备/);
  assert.match(el.textContent, /可用/);
  assert.match(el.textContent, /https:\/\/cc\.example\/clipvault-ostore/);
  assert.ok(el.querySelector('#bkOstoreStats'), 'stats block must live inside the row');

  input.checked = false;
  input.dispatchEvent(new jsdomWindow.Event('change'));
  await new Promise((r) => setTimeout(r, 0));
  const post = calls.find((c) => c.url);
  assert.equal(post.url, 'http://api.test/api/backup/config');
  assert.equal(post.body, JSON.stringify({ ostoreEnabled: false }));
  assert.ok(calls.some((c) => c.toast === '已关闭 ostore 远程冷备'));
  assert.ok(calls.some((c) => c.refresh));
});

test('ostoreRow restores the switch and reports a rejected change', { skip: domSkip }, async () => {
  const { row, calls } = loadOstoreRow(true);
  const el = row({ configured: true, enabled: true, phase: 'ok' });
  const input = el.querySelector('input[data-ostore]');
  input.checked = false;
  input.dispatchEvent(new jsdomWindow.Event('change'));
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(input.checked, true);
  assert.equal(input.disabled, false);
  assert.ok(calls.some((c) => c.toast === '设置失败：保存失败'));
});

test('ostoreRow shows 未配置 with a disabled switch and the config hint', { skip: domSkip }, () => {
  const { row } = loadOstoreRow();
  const el = row({ configured: false, enabled: true, phase: 'not_configured' });
  assert.equal(el.querySelector('input[data-ostore]').disabled, true);
  assert.match(el.textContent, /未配置/);
  assert.match(el.textContent, /config\/ostore-backup\.json/);
});

test('ostoreRow reflects a disabled mirror and the queued state', { skip: domSkip }, () => {
  const { row } = loadOstoreRow();
  const off = row({ configured: true, enabled: false, phase: 'ok' });
  assert.equal(off.querySelector('input[data-ostore]').checked, false);
  const busy = row({ configured: true, enabled: true, phase: 'upload', inProgress: true, queued: true });
  assert.equal(busy.querySelector('input[data-ostore]').checked, true);
  assert.match(busy.textContent, /上传中/);
  assert.match(busy.textContent, /已排队下一轮/);
});
