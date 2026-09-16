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
  assert.match(metricsJs, /function shouldEmit/);
  assert.match(metricsJs, /const SAMPLE = /);
  assert.match(metricsJs, /function scheduleFlush/);
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

test('ingest is self-monitored and exposed on /proc', () => {
  assert.match(swift, /droppedCount/);
  assert.match(swift, /rejectedCount/);
  assert.match(swift, /func stats\(\)/);
  assert.match(web, /json\["metrics"\] = UiMetrics\.shared\.stats\(\)/);
});

test('server side DB and SSE SLIs exist', () => {
  const dbm = src('DatabaseManager.swift');
  assert.match(dbm, /func timedRead/);
  assert.match(dbm, /UiMetrics\.shared\.emit\("db_read"/);
  assert.match(web, /func enqueueSSELocked/);
  assert.match(web, /phase": "coalesce/);
  assert.match(web, /phase": "drop/);
});

test('debug snapshot shows p95 and a baseline delta', () => {
  assert.match(html, /id="nmBaseline"/);
  assert.match(html, /NM_BASELINE_KEY/);
  assert.match(html, /readNmBaseline/);
  assert.match(html, /p95_ms/);
  assert.match(html, /currentSummary/);
});

test('detail is bounded by hourly rollups + incremental vacuum', () => {
  assert.match(swift, /detailRetentionMs/);
  assert.match(swift, /CREATE TABLE IF NOT EXISTS ui_rollup/);
  assert.match(swift, /func rollupLocked/);
  assert.match(swift, /INSERT OR REPLACE INTO ui_rollup/);
  assert.match(swift, /func mergeRollupLocked/);
  assert.match(swift, /rollup_through_hour/);
  // First pass must fold history, not no-op on a completeHour-1 default.
  assert.match(swift, /metaInt\("rollup_through_hour"\) \?\? -1/);
  assert.match(swift, /incremental_vacuum/);
  assert.match(swift, /auto_vacuum=INCREMENTAL/);
});

test('trace correlation id threads wall vs panel', () => {
  assert.match(html, /function newTrace\(\)/);
  assert.match(html, /let pageTrace = newTrace\(\)/);
  assert.match(html, /let sheetTrace = ''/);
  assert.match(html, /n\.startsWith\('wall_'\)[\s\S]{0,140}?e\.trace = pageTrace/);
  assert.match(html, /n\.startsWith\('notes_'\)[\s\S]{0,140}?e\.trace = sheetTrace \|\| pageTrace/);
  assert.match(html, /M\.setTrace\(sheetTrace\)/);
  assert.match(metricsJs, /setTrace\(t\)/);
  assert.match(swift, /func sanitizeTrace/);
  assert.match(swift, /trace TEXT/);
});

test('wall load/hydrate and SSE lifecycle are instrumented', () => {
  assert.match(html, /nm\('wall_load', \{ dur_ms: performance\.now\(\) - wallBootAt/);
  assert.match(html, /wallLoadSent/);
  assert.match(html, /nm\('wall_hydrate', \{ dur_ms: performance\.now\(\) - t0/);
  assert.match(html, /nm\('sse_state', \{ ok: true, payload: \{ kind: 'wall', phase: 'open'/);
  assert.match(html, /nm\('sse_state', \{ ok: false, payload: \{ kind: 'wall', phase: closed \? 'reconnect' : 'error'/);
  assert.match(html, /nm\('sse_state', \{ ok: false, payload: \{ kind: 'wall', phase: 'watch'/);
  assert.match(html, /reconnects/);
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
  assert.match(metricsJs, /const FLUSH_DEBOUNCE_MS = 400/);
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
  assert.match(metricsJs, /'rlim'/);
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
  assert.match(agents, /notes_close\.value` = 开着多久/);
  assert.match(agents, /summary` 另出 p50\/p95\/p99/);
  assert.match(agents, /notes_md_compile/);
  assert.match(agents, /trae_sessions_md/);
});
