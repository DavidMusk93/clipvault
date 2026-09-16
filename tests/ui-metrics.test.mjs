/**
 * Local notes metrics: no content, no sync, separate db file.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const metricsJs = readFileSync(join(root, 'web/assets/notes-metrics.js'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const panelJs = readFileSync(join(root, 'web/assets/metrics-panel.js'), 'utf8');
const swift = src('UiMetrics.swift');
const web = src('WebServer.swift');
const backup = src('CloudDocsBackupService.swift');
const sync = src('CloudDocsSyncService.swift');

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
  assert.match(metricsJs, /'compiled'/);
  assert.match(metricsJs, /'reused'/);
  assert.match(metricsJs, /recentLocal/);
  assert.match(metricsJs, /recordLocal/);
  assert.match(metricsJs, /startsWith\('notes_'\)/);
  assert.match(metricsJs, /FORBIDDEN/);
  assert.match(metricsJs, /body\|title\|markdown/);
  assert.doesNotMatch(metricsJs, /textContent|getMarkdown\(\)/);
});

test('metrics separate latency (dur_ms) from values and budgets', () => {
  // Store columns + additive migration.
  assert.match(swift, /value REAL/);
  assert.match(swift, /over INTEGER/);
  assert.match(swift, /trace TEXT/);
  assert.match(swift, /ensureColumn\("ui_events", "value", "REAL"\)/);
  assert.match(swift, /func percentileLocked\(column: String/);
  assert.match(swift, /p95_ms/);
  assert.match(swift, /ok_rate/);
  assert.match(swift, /func httpRoutesLocked/);

  // Wire format carries value/over/trace.
  assert.match(metricsJs, /ev\.value = extra\.value/);
  assert.match(metricsJs, /ev\.over = extra\.over/);
  assert.match(metricsJs, /ev\.trace = String\(extra\.trace\)/);

  // CLS is a value, not a fake duration.
  assert.match(metricsJs, /emit\('notes_cls', \{\s*value: v,/);
  assert.doesNotMatch(metricsJs, /notes_cls', \{\s*dur_ms: e\.value \* 1000/);
  assert.match(html, /nm\('wall_cls', \{\s*value: clsValue,/);
  assert.doesNotMatch(html, /nm\('wall_cls', \{\s*dur_ms: acc \* 1000/);
  assert.match(html, /nm\('sheet_cls', \{\s*value,/);

  // notes_close reports held time as a value; animation has its own latency.
  assert.match(html, /nm\('notes_close', \{ value: held/);
  assert.match(html, /nm\('notes_close_anim', \{ dur_ms: animMs/);

  // Consumer uses `value` for CLS thresholds.
  assert.match(panelJs, /_cls\$\/\.test\(name\)\) \{[\s\S]{0,160}?ev\.value/);
});

test('frontend wires metrics without sending titles', () => {
  assert.match(html, /assets\/notes-metrics\.js/);
  assert.match(html, /ClipNotesMetrics/);
  assert.match(html, /nm\('note_save'/);
  assert.match(html, /id="nmList"/);
  assert.match(html, /id="debugDrawer"/);
  assert.match(html, /metrics-panel\.js/);
  assert.match(html, /cv-debug-fab|ClipMetricsPanel/);
  assert.match(html, /id="debugHotNotes"/);
  assert.match(html, /id="debugHotSessions"/);
  assert.match(html, /notes_md_compile/);
  assert.match(html, /trae_sessions_md/);
  assert.match(html, /wall_fetch/);
  assert.match(html, /wall_paint/);
  assert.match(html, /wall_ttfp/);
  assert.match(html, /sheet_morph/);
  assert.match(html, /sheet_cls/);
  assert.match(html, /chrome_shift/);
  assert.match(html, /wall_cls/);
  assert.match(html, /wall_longtask/);
  assert.match(html, /function wallLongtaskPayload/);
  assert.match(html, /long-animation-frame/);
  assert.match(html, /phase: 'loaf'/);
  assert.match(html, /phase: 'longtask'/);
  assert.match(html, /function emitChromeShift/);
  assert.match(html, /function snapshotWallChrome/);
  assert.match(metricsJs, /phase: morphing \? 'morph' : 'live'/);
  assert.match(metricsJs, /'dy'/);
  assert.match(metricsJs, /name === 'chrome_shift'/);
  assert.match(metricsJs, /e\.duration < 40/);
  assert.match(metricsJs, /over\$\|out\$\|enter\$\|leave\$/);
  assert.match(html, /ok: value < 0\.1 && ltMax < 50 && dur < 2000/);
  assert.match(swift, /"compiled"/);
  assert.match(swift, /"reused"/);
  assert.match(swift, /"dy"/);
  assert.match(swift, /"fds"/);
  assert.match(swift, /"rss"/);
  assert.match(swift, /"route"/);
  assert.match(swift, /"proto"/);
  assert.match(swift, /drainHttpFront/);
  assert.match(metricsJs, /'route'/);
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
  assert.match(agents, /notes_md_compile/);
  assert.match(agents, /trae_sessions_md/);
});
