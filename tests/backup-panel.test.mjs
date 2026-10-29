/**
 * Backup drawer gate (web/assets/backup-panel.mjs).
 *
 * What can silently break here is the *reading*, not pixels:
 *   - the status card must say the truth (failures, no destination, freshness);
 *   - history must be real runs on a real time axis (dedupe, persisted ostore run
 *     added once, never extrapolated), with a scrub/keyboard reading;
 *   - destinations keep one row shape and the switches keep their config contract;
 *   - SSE progress pings must not collapse an open row.
 *
 * Run via scripts/check-frontend.sh (that script does not glob).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers/src.mjs';
import {
  HISTORY_METRICS, axisTicks, describeRun, destinations, destRowHtml, fmtDur, historyHtml,
  historyRuns, laneStats, mountBackupPanel, ostoreDestination, ostoreStatsHtml, overview,
  relTime, snapshotsHtml,
} from '../web/assets/backup-panel.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const css = readFileSync(join(root, 'web/assets/backup-panel.css'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');
const taste = readFileSync(join(root, 'docs/design-taste.md'), 'utf8');

let JSDOM = null;
try { ({ JSDOM } = await import('jsdom')); } catch { JSDOM = null; }
const domSkip = JSDOM ? false : 'jsdom not installed — run `npm ci`';

const NOW = Date.UTC(2026, 9, 29, 9, 0, 0); // 17:00 Asia/Shanghai
const TZ = 'Asia/Shanghai';

const status = (over = {}) => ({
  enabled: true, inProgress: false, lastSuccessUnix: NOW / 1000 - 300, lastError: null,
  destinations: [
    { id: 'icloud', type: 'icloud', label: 'iCloud Drive', enabled: true, available: true, lastSuccessUnix: NOW / 1000 - 300, lastPhase: 'ok', rootPath: '/icloud' },
    { id: 'gdrive', type: 'gdrive', label: 'Google Drive', enabled: true, available: true, lastSuccessUnix: NOW / 1000 - 300, lastPhase: 'ok', rootPath: '/gdrive' },
    { id: 'quark', type: 'quark', label: '夸克网盘', enabled: true, available: true, lastSuccessUnix: NOW / 1000 - 300, lastPhase: 'ok:staging_cloud_listed', rootPath: '/quark', hint: '本机暂存 …' },
  ],
  ostore: { configured: true, enabled: true, phase: 'ok', lastSuccessUnix: NOW / 1000 - 600, baseURL: 'https://cc.example/clipvault-ostore' },
  latest: { id: 'latest', isLatest: true, origin: 'self', createdAtUnix: NOW / 1000 - 300, byteSize: 107000000, itemCount: 5816, sha256: 'abc' },
  snapshots: [],
  ...over,
});

// ---------------------------------------------------------------- wiring

test('gate + lazy wiring: module loads only when the drawer opens', () => {
  assert.match(check, /backup-panel\.test\.mjs/);
  assert.match(html, /<div id="bkPanel"/);
  assert.match(html, /import\('\/assets\/backup-panel\.mjs\?v=/);
  assert.match(html, /link\.href = '\/assets\/backup-panel\.css\?v=/);
  // Status repaint is SSE driven: the wall must not poll /api/backup/status.
  assert.doesNotMatch(html, /setInterval\([^)]*refreshBackupStatus/);
  // The old in-page renderers are gone; one renderer, one place.
  for (const dead of ['function paintOstoreStats', 'function ostoreRow', 'function refreshBackupHistory', 'function refreshBackupMetrics', 'id="bkRunNow"']) {
    assert.ok(!html.includes(dead), `index.html still has ${dead}`);
  }
  assert.deepEqual(HISTORY_METRICS, ['backup_cycle', 'backup_local_run', 'backup_ostore_run']);
  assert.match(taste, /## 备份面板/);
});

test('css: data marks are square, colour is semantic, motion respects reduce', () => {
  assert.match(css, /\.bkh-mark \{[^}]*border-radius: 0/);
  assert.match(css, /\.bkh-mark\[data-state="fail"\] \{ background: var\(--danger\)/);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.match(css, /\.bk-compose-bar \{ display: flex; gap: 3px/);
  // hover never changes geometry: the readout and crosshair are absolutely placed
  assert.match(css, /\.bkh-readout \{\s*position: absolute/);
  assert.match(css, /\.bkh-guide \{\s*position: absolute/);
});

// ---------------------------------------------------------------- status card

test('overview: fresh, failing, running and no-destination readings', () => {
  const ok = overview(status(), NOW);
  assert.equal(ok.tone, 'ok');
  assert.equal(ok.title, '已备份');
  assert.match(ok.detail, /上次成功 5 分钟前 · 4 \/ 4 个位置正常/);

  const failing = overview(status({ lastError: '磁盘已满' }), NOW);
  assert.equal(failing.tone, 'bad');
  assert.equal(failing.error, '磁盘已满');

  assert.equal(overview(status({ inProgress: true }), NOW).title, '正在备份');

  const none = status();
  none.destinations = none.destinations.map((d) => ({ ...d, available: false }));
  assert.equal(overview(none, NOW).title, '没有可用的备份位置');

  const osFail = status({ ostore: { configured: true, enabled: true, phase: 'error', lastError: 'The network connection was lost.' } });
  assert.match(overview(osFail, NOW).detail, /3 \/ 4 个位置正常/);
});

test('relTime / fmtDur speak human units', () => {
  assert.equal(relTime(NOW / 1000 - 10, NOW), '刚刚');
  assert.equal(relTime(NOW / 1000 - 3 * 3600, NOW), '3 小时前');
  assert.equal(fmtDur(820), '820 ms');
  assert.equal(fmtDur(1600), '1.6 秒');
  assert.equal(fmtDur(388147), '6 分 28 秒');
});

// ---------------------------------------------------------------- destinations

test('destinations: four rows, one shape; 夸克 says staging on the row', () => {
  const rows = destinations(status());
  assert.deepEqual(rows.map((r) => r.id), ['icloud', 'gdrive', 'quark', 'ostore']);
  const quark = rows.find((r) => r.id === 'quark');
  assert.equal(quark.state, '云端可见');
  assert.equal(quark.note, '本地暂存；云端完整性尚未验证');
  const row = destRowHtml(quark, { nowMs: NOW });
  assert.match(row, /data-dest="quark" checked/);
  assert.match(row, /本地暂存；云端完整性尚未验证/);
  assert.match(row, /aria-expanded="false"/);
  assert.match(row, /<div class="bk-dest-more"[^>]* hidden>/);
});

test('ostore row: configured / off / running / failed, progress is real counts', () => {
  assert.equal(ostoreDestination({ configured: false }).state, '未配置');
  assert.match(destRowHtml(ostoreDestination({ configured: false })), /data-ostore="1" disabled/);
  assert.equal(ostoreDestination({ configured: true, enabled: false }).state, '已关闭');
  const busy = ostoreDestination({ configured: true, enabled: true, inProgress: true, total: 1511, uploaded: 5, skipped: 1504, failed: 0, queued: true });
  assert.equal(busy.tone, 'busy');
  assert.deepEqual(busy.progress, { done: 1509, total: 1511 });
  const row = destRowHtml(busy);
  assert.match(row, /1,509 \/ 1,511/);
  assert.match(row, /已排队下一轮/);
  assert.match(row, /role="progressbar"[^>]*aria-valuenow="1509"/);
  const failed = ostoreDestination({ configured: true, enabled: true, phase: 'error', lastError: 'The network connection was lost.' });
  assert.equal(failed.state, '上次失败');
  assert.match(destRowHtml(failed, { open: true }), /The network connection was lost\./);
});

test('ostore stats: composition has numbers and shares; restart keeps last run', () => {
  const live = ostoreStatsHtml({ configured: true, inProgress: true, total: 10, uploaded: 2, skipped: 6, failed: 1, pending: 1, uploadedBytes: 2048, skippedBytes: 4096 });
  assert.match(live, /共 10 个/);
  assert.match(live, /已跳过<b class="bk-num">6<\/b><span class="bk-num">60\.0%<\/span>/);
  assert.match(live, /data-seg="failed" style="flex:1"/);
  assert.match(live, /本轮对象<\/dt><dd>上传 2 · 跳过 6 · 未完成 1 · 失败 1 \/ 共 10/);

  const restarted = ostoreStatsHtml({ configured: true, total: 0, remoteObjects: 1508, remoteBytes: 820000000,
    lastRun: { phase: 'ok', total: 1507, uploaded: 3, skipped: 1504, failed: 0, durationSeconds: 339.7, finishedUnix: 1793264172 } }, { formatTime: () => 'T' });
  assert.match(restarted, /上次运行对象/);
  assert.match(restarted, /远端对象<\/dt><dd>1,508 对象/);
  assert.match(restarted, /上次运行<\/dt><dd>T · 成功 · 上传 3 · 跳过 1,504 · 5 分 40 秒/);
  assert.doesNotMatch(restarted, /本轮对象<\/dt>/);

  assert.match(ostoreStatsHtml({ configured: false }), /config\/ostore-backup\.json/);
});

// ---------------------------------------------------------------- history

const metric = (name, minsAgo, durMs, ok, payload) => ({ name, ts: NOW - minsAgo * 60000, dur_ms: durMs, ok, payload });

test('historyRuns: dedupes manual twins, adds the persisted ostore run once, keeps errors', () => {
  const fromMs = NOW - 86400000;
  const datasets = [
    [metric('backup_cycle', 50, 1300, true)],
    [metric('backup_local_run', 50, 1300, true, { kind: 'manual' }), metric('backup_local_run', 20, 2100, false, { kind: 'automatic' })],
    [metric('backup_ostore_run', 10, 388000, false, { applied: 0, reused: 1504, bytes: 0 })],
  ];
  const runs = historyRuns(datasets, { lastRun: { finishedUnix: (NOW - 10 * 60000) / 1000, durationSeconds: 388, phase: 'error', error: 'The network connection was lost.' } }, fromMs);
  assert.deepEqual(runs.map((r) => [r.lane, r.kind, r.ok]), [['local', 'manual', true], ['local', 'automatic', false], ['ostore', 'ostore', false]]);
  assert.equal(runs[2].error, 'The network connection was lost.');
  assert.equal(runs[2].persisted, false);

  const persisted = historyRuns([[], [], []], { lastRun: { finishedUnix: (NOW - 3600000) / 1000, durationSeconds: 2, phase: 'ok', uploaded: 1, skipped: 4, uploadedBytes: 10 } }, fromMs);
  assert.equal(persisted.length, 1);
  assert.equal(persisted[0].persisted, true);
  assert.match(describeRun(persisted[0], { timeZone: TZ }), /留存的上次运行/);

  const outside = historyRuns([[], [], []], { lastRun: { finishedUnix: (fromMs - 1000) / 1000, durationSeconds: 2, phase: 'ok' } }, fromMs);
  assert.equal(outside.length, 0, 'a persisted run outside the window is not drawn');
});

test('history chart: real time axis, per-lane facts, failures red, live band, slider a11y', () => {
  const fromMs = NOW - 86400000;
  const runs = historyRuns([[metric('backup_cycle', 120, 1300, true), metric('backup_cycle', 60, 1700, true)], [metric('backup_local_run', 30, 2100, false, { kind: 'automatic' })], []], null, fromMs);
  const out = historyHtml(runs, { fromMs, toMs: NOW, days: 1, live: { startMs: NOW - 5 * 60000 }, pin: runs.length - 1, timeZone: TZ });
  assert.match(out, /<span>本机<\/span><b class="bk-num">3 次<\/b><span class="bk-num">中位 1\.7 秒<\/span>/);
  assert.match(out, /data-mark="fail-local"[^>]*><b class="bk-num">1 次失败<\/b>/);
  assert.match(out, /<span>ostore<\/span><b class="bk-num">0 次<\/b>/);
  assert.match(out, /class="bkh-live"/);
  assert.match(out, /data-i="2" data-state="fail"/);
  assert.match(out, /class="bkh-mark is-pin" data-i="2"/);
  // marks are placed by time, not packed side by side
  const left = (i) => Number(out.match(new RegExp(`data-i="${i}"[^>]*left:([0-9.]+)%`))[1]);
  assert.ok(left(0) < left(1) && left(1) < left(2));
  assert.ok(Math.abs(left(2) - (1 - 30 / 1440) * 100) < 0.01);
  assert.match(out, /role="slider"[^>]*aria-valuemax="2"[^>]*aria-valuenow="2"[^>]*aria-valuetext="自动本机备份/);
  assert.match(out, /24 小时前/);
  assert.match(out, /现在/);

  assert.deepEqual(laneStats([]), { n: 0, fails: 0, p50: null, max: null });
  assert.match(historyHtml([], { fromMs, toMs: NOW }), /此时间范围暂无运行/);
});

test('axis ticks land on the display clock', () => {
  const day = axisTicks(NOW - 86400000, NOW, { days: 1, timeZone: TZ }).map((t) => t.label);
  assert.deepEqual(day, ['00:00', '06:00', '12:00']);
  const week = axisTicks(NOW - 7 * 86400000, NOW, { days: 7, timeZone: TZ }).map((t) => t.label);
  assert.ok(week.every((l) => /^\d{1,2}\/\d{1,2}$/.test(l)) && week.length >= 4);
});

test('restore points: newest first, labelled, every row has a restore action', () => {
  const out = snapshotsHtml(status({ snapshots: [{ id: '20261029-162116', origin: 'self', createdAtUnix: NOW / 1000 - 7200, byteSize: 100, itemCount: 5800 }, { id: 'peer', origin: 'peer', host: 'macbook-pro', createdAtUnix: NOW / 1000 - 86400 }] }), { nowMs: NOW, formatTime: () => 'T' });
  assert.match(out, /<b>最新备份<\/b><span class="bk-num">本机最新 · 5 分钟前 · 102\.0 MB · 5,816 条/);
  assert.match(out, /<b>T<\/b><span class="bk-num">本机快照 · 2 小时前/);
  assert.match(out, /<b>macbook-pro<\/b><span class="bk-num">其他机器 · macbook-pro · 1 天前/);
  assert.equal((out.match(/data-restore=/g) || []).length, 3);
  assert.match(snapshotsHtml({}), /暂无可恢复的时间点/);
});

// ---------------------------------------------------------------- DOM: the mounted panel

function mount({ fail = false, history = null } = {}) {
  const dom = new JSDOM('<!doctype html><div id="bkPanel"></div>', { pretendToBeVisual: true });
  const calls = [];
  const events = history || {
    backup_cycle: [metric('backup_cycle', 120, 1300, true)],
    backup_local_run: [metric('backup_local_run', 30, 2100, false, { kind: 'automatic' })],
    backup_ostore_run: [metric('backup_ostore_run', 10, 388000, true, { applied: 3, reused: 1504, bytes: 215000000 })],
  };
  const fetch = async (url, opts) => {
    calls.push({ url, body: opts?.body });
    if (url.includes('/api/ui-metrics/recent')) {
      const name = new URL(url, 'http://x').searchParams.get('name');
      return { ok: true, json: async () => ({ ok: true, events: events[name] || [] }) };
    }
    if (fail) return { ok: false, json: async () => ({ ok: false, message: '保存失败' }) };
    if (url.endsWith('/api/backup/run')) return { ok: true, json: async () => ({ ok: true, message: '已备份' }) };
    return { ok: true, json: async () => ({ ok: true }) };
  };
  const toasts = [];
  let refreshed = 0;
  const panel = mountBackupPanel({
    root: dom.window.document.getElementById('bkPanel'), api: '', fetch,
    toast: (m) => toasts.push(m), confirm: () => true,
    formatTime: () => 'T', timeZone: () => TZ, now: () => NOW,
    refreshStatus: () => { refreshed += 1; },
  });
  return { dom, doc: dom.window.document, panel, calls, toasts, refreshed: () => refreshed };
}
const tickIO = () => new Promise((r) => setTimeout(r, 0));

test('mounted: status card + four rows + restore list paint from one status', { skip: domSkip }, () => {
  const { doc, panel } = mount();
  panel.paint(status());
  assert.equal(doc.getElementById('bkOverviewTitle').textContent, '已备份');
  assert.equal(doc.querySelector('.bk-hero').dataset.tone, 'ok');
  assert.equal(doc.getElementById('backupEnabled').checked, true);
  assert.equal(doc.querySelectorAll('#bkDestList > .bk-dest').length, 4);
  assert.equal(doc.getElementById('bkDestSummary').textContent, '4 / 4 已启用');
  assert.equal(doc.querySelectorAll('#bkSnaps [data-restore]').length, 1);
  assert.match(doc.getElementById('bkDiag').textContent, /上次成功/);
});

test('mounted: an open row survives a progress ping; focus stays put', { skip: domSkip }, () => {
  const { doc, panel } = mount();
  panel.paint(status({ ostore: { configured: true, enabled: true, inProgress: true, total: 1511, uploaded: 1, skipped: 1504, phase: 'upload' } }));
  const toggle = doc.querySelector('[data-dest-toggle="ostore"]');
  toggle.focus();
  toggle.click();
  assert.equal(toggle.getAttribute('aria-expanded'), 'true');
  assert.match(doc.getElementById('bkOstoreStats').textContent, /本轮对象/);
  panel.paint(status({ ostore: { configured: true, enabled: true, inProgress: true, total: 1511, uploaded: 3, skipped: 1504, phase: 'upload' } }));
  const again = doc.querySelector('[data-dest-toggle="ostore"]');
  assert.equal(again.getAttribute('aria-expanded'), 'true');
  assert.equal(doc.querySelector('#bkDestMore-ostore').hidden, false);
  assert.equal(doc.activeElement, again);
  assert.match(doc.querySelector('[data-dest-row="ostore"] .bk-dest-status').textContent, /1,507 \/ 1,511/);
});

test('mounted: switches post the config contract and roll back on rejection', { skip: domSkip }, async () => {
  const ok = mount();
  ok.panel.paint(status());
  const os = ok.doc.querySelector('input[data-ostore]');
  os.checked = false;
  os.dispatchEvent(new ok.dom.window.Event('change', { bubbles: true }));
  await tickIO();
  assert.ok(ok.calls.some((c) => c.url === '/api/backup/config' && c.body === JSON.stringify({ ostoreEnabled: false })));
  assert.ok(ok.toasts.includes('已关闭 ostore 远程冷备'));
  const g = ok.doc.querySelector('input[data-dest="gdrive"]');
  g.checked = false;
  g.dispatchEvent(new ok.dom.window.Event('change', { bubbles: true }));
  await tickIO();
  assert.ok(ok.calls.some((c) => c.body === JSON.stringify({ destinationId: 'gdrive', destinationEnabled: false })));

  const bad = mount({ fail: true });
  bad.panel.paint(status());
  const input = bad.doc.querySelector('input[data-ostore]');
  input.checked = false;
  input.dispatchEvent(new bad.dom.window.Event('change', { bubbles: true }));
  await tickIO();
  assert.equal(input.checked, true);
  assert.equal(input.disabled, false);
  assert.ok(bad.toasts.includes('设置失败：保存失败'));
  assert.ok(bad.refreshed() >= 1);
});

test('mounted: history loads three metrics, pins the latest, arrows walk the runs', { skip: domSkip }, async () => {
  const { doc, panel, calls, dom } = mount();
  panel.paint(status());
  await panel.refreshHistory();
  const names = calls.filter((c) => c.url.includes('/recent')).map((c) => new URL(c.url, 'http://x').searchParams.get('name'));
  assert.deepEqual(names, HISTORY_METRICS);
  assert.equal(doc.querySelectorAll('.bkh-mark').length, 3);
  assert.match(doc.getElementById('bkHistoryDetail').textContent, /^成功ostore 上传/);
  assert.match(doc.getElementById('bkHistoryDetail').textContent, /跳过.*1,504/);
  const plot = doc.querySelector('.bkh-plot');
  plot.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }));
  assert.match(doc.getElementById('bkHistoryDetail').textContent, /^失败自动本机备份/);
  assert.equal(plot.getAttribute('aria-valuenow'), '1');
  assert.equal(doc.querySelector('.bkh-mark.is-pin').dataset.i, '1');
  plot.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
  assert.match(doc.getElementById('bkHistoryDetail').textContent, /手动本机备份/);

  // switching the window refetches with the new range
  const before = calls.length;
  doc.querySelector('[data-history-days="7"]').click();
  await tickIO(); await tickIO();
  assert.equal(calls.length - before, 3);
  assert.equal(doc.querySelector('[data-history-days="7"]').getAttribute('aria-checked'), 'true');
});

test('mounted: 立即备份 shows progress in place and reports the result', { skip: domSkip }, async () => {
  const { doc, panel, calls } = mount();
  panel.paint(status());
  const btn = doc.getElementById('bkRunNow');
  btn.click();
  assert.equal(btn.disabled, true);
  assert.equal(doc.getElementById('bkOverviewTitle').textContent, '正在备份');
  await tickIO(); await tickIO(); await tickIO();
  assert.ok(calls.some((c) => c.url === '/api/backup/run'));
  assert.equal(btn.disabled, false);
  assert.match(doc.getElementById('bkActionStatus').textContent, /^完成 · /);
});
