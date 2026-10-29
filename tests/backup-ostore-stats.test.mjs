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

test('each finished ostore run is recorded for the history chart', () => {
  const fin = sliceFrom(ostore, 'private func finish(', 2600);
  assert.match(fin, /UiMetrics\.shared\.emit\("backup_ostore_run"/);
  assert.match(fin, /"applied": run\.uploaded, "reused": run\.skipped/);
  const local = src('CloudDocsBackupService.swift');
  assert.match(local, /UiMetrics\.shared\.emit\("backup_local_run"/);
});
