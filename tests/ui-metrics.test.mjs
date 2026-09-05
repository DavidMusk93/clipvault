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
  assert.match(swift, /ui-metrics\.db/);
  assert.match(swift, /maxEventsPerRequest = 100/);
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
  assert.match(metricsJs, /FORBIDDEN/);
  assert.match(metricsJs, /body\|title\|markdown/);
  assert.doesNotMatch(metricsJs, /textContent|getMarkdown\(\)/);
});

test('frontend wires metrics without sending titles', () => {
  assert.match(html, /assets\/notes-metrics\.js/);
  assert.match(html, /ClipNotesMetrics/);
  assert.match(html, /nm\('note_save'/);
  assert.match(html, /id="nmList"/);
  assert.doesNotMatch(html, /nm\([^)]*title/);
  assert.doesNotMatch(html, /payload:\s*\{[^}]*title/);
});
