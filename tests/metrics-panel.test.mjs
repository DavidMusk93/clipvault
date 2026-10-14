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
const sess = readFileSync(join(root, 'trae_hooks/web/sessions-vanilla.html'), 'utf8');
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

test('floating panel labels paths and offers a full-panel jump', () => {
  assert.match(js, /const LABEL = \{/);
  assert.match(js, /function labelOf\(name\)/);
  assert.match(js, /cv-metrics-more/);
  assert.match(js, /onMore/);
  assert.doesNotMatch(js, /p95/);
});

test('wall family stays a lightweight popover family', () => {
  assert.match(js, /wall: \[/);
  assert.match(js, /wall_hydrate/);
  assert.match(js, /family === 'wall'/);
  assert.doesNotMatch(js, /p95/);
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

/** Brace-matched function body out of the inline app script. */
function fnSource(name) {
  const start = html.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `missing ${name}`);
  const open = html.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth += 1;
    else if (html[i] === '}') {
      depth -= 1;
      if (depth === 0) return html.slice(start, i + 1);
    }
  }
  throw new Error(`${name} unbalanced`);
}

function metricSpec() {
  const at = html.indexOf('const METRIC_SPEC = {');
  assert.ok(at >= 0, 'missing METRIC_SPEC');
  const open = html.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth += 1;
    else if (html[i] === '}') {
      depth -= 1;
      if (depth === 0) return new Function(`return ${html.slice(open, i + 1)};`)();
    }
  }
  throw new Error('METRIC_SPEC unbalanced');
}

// 2026-10-14: the live socket churn (~1/min) and the stale wall never went red, because
// `sse_state` had `budget: null` and every undeclared name silently defaulted to no
// budget. A metric you cannot fail is not a metric.
test('loss-critical names carry a budget, and undeclared names are flagged', () => {
  const spec = metricSpec();
  assert.equal(spec.wall_head_drift.budget, 0, 'model-vs-server drift must be red at any value');
  assert.equal(spec.sse_churn.budget, 0);
  assert.equal(spec.sse_socket_churn.budget, 3);
  assert.equal(spec.capture_gap.budget, 0);
  for (const name of ['wall_head_drift', 'sse_churn', 'sse_socket_churn', 'capture_gap']) {
    assert.match(html, new RegExp(`${name}: \\{ label:`), `${name} must be declared, not inherited`);
  }

  const metricMeta = new Function(
    'METRIC_SPEC',
    `${fnSource('metricMeta')}\nreturn metricMeta;`,
  )(spec);
  assert.equal(metricMeta('wall_head_drift').budget, 0);
  assert.equal(metricMeta('sse_state').budget, null);
  assert.equal(metricMeta('sse_state').nobudget, undefined, 'declared context-only is a choice');
  assert.equal(metricMeta('sse_brand_new_thing').nobudget, true, 'undeclared => visibly unbudgeted');
  assert.equal(metricMeta('wall_something_new').nobudget, true);
  assert.equal(metricMeta('wall_paint').budget, 50, 'declared names still resolve');
  // The panel must say it out loud instead of showing a neutral dash / clean verdict.
  assert.match(html, /is-nobudget/);
  assert.match(html, /无预算/);
  assert.match(html, /个指标未声明（无预算，永不判红）/);
});
