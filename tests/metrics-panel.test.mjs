/**
 * Notes/sessions metrics: floating debug toggle, compact popover, key names only.
 * Run: node --test tests/metrics-panel.test.mjs
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const js = readFileSync(join(root, 'web/assets/metrics-panel.js'), 'utf8');
const css = readFileSync(join(root, 'web/assets/metrics-panel.css'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const sess = readFileSync(join(root, 'trae_hooks/web/sessions.html'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');

test('popover keeps skip/paint and compile/preview, drops 24h essays', () => {
  assert.match(js, /function diagnose/);
  assert.match(js, /notes_preview_ms/);
  assert.match(js, /notes_md_compile/);
  assert.match(js, /trae_sessions_skip/);
  assert.match(js, /trae_sessions_paint/);
  assert.match(js, /cv-debug-fab/);
  assert.match(js, /function toggle/);
  assert.doesNotMatch(js, /24 小时/);
  assert.doesNotMatch(js, /p95/);
  assert.match(css, /\.cv-metrics-float \{[\s\S]{0,80}right:\s*16px/);
  assert.match(css, /\.cv-debug-fab \{\n  height: 28px;/);
  assert.match(css, /border: 0\.5px solid/);
  assert.match(css, /background: transparent;/);
  assert.match(css, /\.cv-debug-fab\.is-slow \{[\s\S]{0,80}#D70015/);
  assert.match(css, /\.cv-metrics-pop/);
  assert.doesNotMatch(css, /cv-debug-fab-dot/);
  assert.doesNotMatch(js, /cv-debug-fab-dot/);
  assert.doesNotMatch(js, /cv-debug-n/);
  assert.doesNotMatch(css, /\.cv-debug-row/);
});

test('notes and sessions mount a bottom-right debug fab, not a full paper', () => {
  assert.match(js, /function destroy/);
  assert.match(html, /function ensureNotesMetrics/);
  assert.match(html, /function teardownNotesMetrics/);
  assert.match(html, /#notesPanel \.notes-shell/);
  assert.doesNotMatch(html, /id="notesDebugRow"/);
  assert.doesNotMatch(html, /id="notesMetrics"/);
  assert.doesNotMatch(html, /setNotesMetricsOpen/);
  assert.doesNotMatch(html, /notes-paper\.is-metrics/);
  assert.match(sess, /family: "sessions"/);
  assert.match(sess, /document\.querySelector\("\.app"\)/);
  assert.doesNotMatch(sess, /id="sessDebugRow"/);
  assert.doesNotMatch(sess, /id="sessMetrics"/);
  assert.doesNotMatch(sess, /setSessMetricsOpen/);
  assert.match(html, /metrics-panel\.css\?v=m4/);
  assert.match(sess, /metrics-panel\.css\?v=m4/);
});

test('AGENTS.md points at the floating debug card', () => {
  assert.match(agents, /右下角透明「调试」/);
  assert.match(agents, /随子页生灭/);
});
