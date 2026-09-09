/**
 * Local notes metrics: no content, no sync, separate db file.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const metricsJs = readFileSync(join(root, 'web/assets/notes-metrics.js'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const swift = readFileSync(join(root, 'ClipFlow/UiMetrics.swift'), 'utf8');
const web = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');
const backup = readFileSync(join(root, 'ClipFlow/CloudDocsBackupService.swift'), 'utf8');
const sync = readFileSync(join(root, 'ClipFlow/CloudDocsSyncService.swift'), 'utf8');

test('metrics API and db are local-only', () => {
  assert.match(web, /\/api\/ui-metrics/);
  assert.match(web, /handleUiMetricsIngest/);
  assert.match(web, /handleUiMetricsSummary/);
  assert.match(web, /handleUiMetricsRecent/);
  assert.match(web, /\/api\/ui-metrics\/recent/);
  assert.match(swift, /ui-metrics\.db/);
  assert.match(swift, /maxEventsPerRequest = 100/);
  assert.match(swift, /func recent\(/);
  assert.match(swift, /"w"/);
  assert.match(swift, /"h"/);
  assert.match(swift, /"nodes"/);
  assert.match(sync, /UiMetrics\.shared\.emit/);
  assert.match(sync, /sync_cycle/);
  assert.match(sync, /sync_blob_wait/);
  assert.doesNotMatch(sync, /ui-metrics\.db/);
  assert.doesNotMatch(backup, /ui-metrics\.db/);
  assert.match(backup, /clipflow\.db/);
});

test('payload forbids note content keys', () => {
  assert.match(swift, /forbiddenPayload/);
  assert.match(swift, /"body"/);
  assert.match(swift, /"title"/);
  assert.match(swift, /"markdown"/);
  assert.match(swift, /"kind"/);
  assert.match(swift, /"reason"/);
  assert.match(swift, /"lag"/);
  assert.match(metricsJs, /'w'/);
  assert.match(metricsJs, /'nodes'/);
  assert.match(metricsJs, /recentLocal/);
  assert.match(metricsJs, /startsWith\('wall_'\)/);
  assert.match(metricsJs, /FORBIDDEN/);
  assert.match(metricsJs, /body\|title\|markdown/);
  assert.doesNotMatch(metricsJs, /textContent|getMarkdown\(\)/);
});

test('frontend wires metrics without sending titles', () => {
  assert.match(html, /assets\/notes-metrics\.js/);
  assert.match(html, /ClipNotesMetrics/);
  assert.match(html, /nm\('note_save'/);
  assert.match(html, /id="nmList"/);
  assert.match(html, /id="debugDrawer"/);
  assert.match(html, /wall_fetch/);
  assert.match(html, /wall_paint/);
  assert.match(html, /wall_ttfp/);
  assert.match(html, /sheet_morph/);
  assert.match(html, /sheet_cls/);
  assert.match(html, /chrome_shift/);
  assert.match(html, /wall_cls/);
  assert.match(html, /function emitChromeShift/);
  assert.match(html, /function snapshotWallChrome/);
  assert.match(metricsJs, /phase: morphing \? 'morph' : 'live'/);
  assert.match(metricsJs, /'dy'/);
  assert.match(metricsJs, /name === 'chrome_shift'/);
  assert.match(metricsJs, /e\.duration < 40/);
  assert.match(metricsJs, /over\$\|out\$\|enter\$\|leave\$/);
  assert.match(html, /ok: value < 0\.1 && ltMax < 50 && dur < 2000/);
  assert.match(swift, /"dy"/);
  assert.match(swift, /"fds"/);
  assert.match(swift, /"rss"/);
  assert.match(swift, /"unix"/);
  assert.match(swift, /"rlim"/);
  assert.match(web, /\/api\/ui-metrics\/proc/);
  assert.match(web, /handleProcMetrics/);
  assert.match(web, /proc_sample/);
  assert.match(html, /debugProcKv/);
  assert.match(html, /d\.fds/);
  assert.match(metricsJs, /'fds'/);
  assert.match(metricsJs, /proc_sample/);
  assert.doesNotMatch(html, /nm\([^)]*title/);
  assert.doesNotMatch(html, /payload:\s*\{[^}]*title/);
});

test('AGENTS.md requires metrics-based UI iteration', () => {
  const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
  assert.match(agents, /开发迭代 = metrics-based optimization/);
  assert.match(agents, /^## Metrics$/m);
  assert.match(agents, /chrome_shift/);
  assert.match(agents, /wall_cls/);
  assert.match(agents, /先补点，再改/);
  assert.match(agents, /notes_close\.dur_ms` = 开着墙钟/);
});
