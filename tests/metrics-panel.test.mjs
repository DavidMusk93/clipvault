/**
 * Notes/sessions metrics live in a shared paper, not a 11px chip.
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

test('shared panel diagnoses skip vs paint and compile vs preview', () => {
  assert.match(js, /function diagnose/);
  assert.match(js, /notes_preview_ms/);
  assert.match(js, /notes_md_compile/);
  assert.match(js, /trae_sessions_skip/);
  assert.match(js, /trae_sessions_paint/);
  assert.match(js, /payload\.reason/);
  assert.match(js, /data-act="copy"/);
  assert.match(js, /24 小时/);
  assert.match(js, /p95/);
  assert.match(css, /\.cv-metrics/);
  assert.match(css, /\.cv-debug-row/);
  assert.match(css, /\.cv-att/);
});

test('notes and sessions use the same left-rail debug row', () => {
  assert.match(html, /id="notesDebugRow"/);
  assert.match(html, /id="notesMetrics"/);
  assert.match(html, /setNotesMetricsOpen\(true\)/);
  assert.match(html, /notes-paper\.is-metrics/);
  assert.doesNotMatch(html, /id="notesPerf"/);
  assert.match(sess, /id="sessDebugRow"/);
  assert.match(sess, /id="sessMetrics"/);
  assert.match(sess, /setSessMetricsOpen\(true\)/);
  assert.doesNotMatch(sess, /id="sessPerf"/);
  assert.match(html, /metrics-panel\.css/);
  assert.match(sess, /metrics-panel\.css/);
});

test('AGENTS.md forbids a chip standing in for the panel', () => {
  assert.match(agents, /左栏底「指标」/);
  assert.match(agents, /禁止用一条 11px 文案代替面板/);
});
