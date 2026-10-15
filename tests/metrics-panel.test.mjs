/**
 * Notes/sessions metrics: floating debug toggle, compact popover, key names only.
 * Run: node --test tests/metrics-panel.test.mjs
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'path';
import test from 'node:test';
import { root, src } from './helpers/src.mjs';

const js = readFileSync(join(root, 'web/assets/metrics-panel.js'), 'utf8');
const css = readFileSync(join(root, 'web/assets/metrics-panel.css'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const sess = readFileSync(join(root, 'trae_hooks/web/sessions-vanilla.html'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
const web = src('WebServer.swift');

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

// 2026-10-15: 调试 aggregated the ring buffer in JS (interpolated) while 备份 showed the
// server summary (SQL `CAST(cnt*p)`), and the floor form reported the *minimum* as a p95
// for two samples — the panel understated exactly the tail it sorts and reddens by. One
// definition, pinned in tests/metrics-sql.test.mjs on both sides.
test('quantities are readable and carry their unit', () => {
  const fmtVal = new Function(`${fnSource('fmtVal')}\nreturn fmtVal;`)();
  const budgetLabel = new Function(`${fnSource('budgetLabel')}\nreturn budgetLabel;`)();

  // The magnitudes that were on screen: 1425663ms (parked), 2272259.714 (drawer open),
  // p95v 4827425.000. A number nobody can read is a number nobody checks.
  assert.equal(fmtVal(1425663, 'ms'), '23.8min');
  assert.equal(fmtVal(2272259.714, 'ms'), '37.9min');
  assert.equal(fmtVal(3954105, 'ms'), '1.1h');
  assert.equal(fmtVal(3 * 3600000, 'ms'), '3.0h');
  assert.equal(fmtVal(682.4, 'ms'), '682ms');
  assert.equal(fmtVal(2740, 'ms'), '2.74s');
  assert.equal(fmtVal(0.043, 'cls'), '0.043');
  assert.equal(fmtVal(730, 'px'), '730px');
  assert.equal(fmtVal(1862, 'count'), '1862');
  assert.equal(fmtVal(null, 'ms'), '—');
  assert.equal(fmtVal(NaN, 'ms'), '—');

  assert.equal(budgetLabel({ budget: 300, unit: 'ms' }), '300ms');
  assert.equal(budgetLabel({ budget: 0, unit: 'px' }), '0px');
  assert.equal(budgetLabel({ budget: 0.1, unit: 'cls' }), '0.1');
  assert.equal(budgetLabel({ budget: 3, unit: 'count' }), '3');
  assert.equal(budgetLabel({ budget: null, unit: 'ms' }), '—');

  // Both panels format through the same helper (no `avg v 2272259.714` readout left).
  assert.match(html, /fmtVal\(row\.avg_ms, unit\)/);
  assert.match(html, /fmtVal\(row\.value_p95, unit\)/);
  assert.doesNotMatch(html, /avg v \$/);
  assert.doesNotMatch(html, /p95v \$/);
});

test('declared names carry an honest unit, and no budget is a no-op', () => {
  const spec = metricSpec();
  const units = new Set(['ms', 'cls', 'px', 'count']);
  for (const [name, meta] of Object.entries(spec)) {
    if (meta.unit == null) continue;
    assert.ok(units.has(meta.unit), `${name}: unknown unit ${meta.unit}`);
    if (meta.budget == null) continue;
    // ms budgets exist to be exceeded; 60s on a status read never was.
    const ceiling = meta.unit === 'ms' ? 60000 : 1e9;
    assert.ok(meta.budget <= ceiling, `${name}: budget ${meta.budget} is a no-op`);
  }
  // The two that were lying on screen: a px metric shown as a bare `0`, and a budget 200x
  // its measured p95 (wall_backup p95 529ms over 549 samples, server avg 77ms).
  assert.equal(spec.wall_layout_drift.unit, 'px');
  assert.equal(spec.wall_layout_drift.budget, 0);
  assert.equal(spec.wall_backup.budget, 300);
  // Duration-of-stay / usage counters are context: declared, unit-carrying, never red —
  // but never presented as a response time either.
  for (const name of ['notes_open', 'notes_close', 'notes_mode', 'note_switch', 'note_new']) {
    assert.equal(spec[name].budget, null, `${name} is context, not latency`);
    assert.match(spec[name].label, /时长|打开|切换|新建/, `${name} label must say what it measures`);
  }
  // The button label must match the data it pulls (`/recent?limit=200`, not a 24h window).
  assert.match(html, /id="debugPull">服务器 recent</);
  assert.doesNotMatch(html, /id="debugPull">[^<]*24h/);
});

// Two sampling blind spots found while verifying the churn fix live: an idle wall never
// runs `mergeHead` (so no drift sample existed at all), and a churn rate sampled only at
// socket-open can never show "0 opens in 5 min" — absence is not evidence.
test('an idle wall still samples drift, and churn cools to an explicit zero', () => {
  assert.match(html, /const WALL_DRIFT_ASSURE_MS = 180000;/);
  assert.match(html, /__cvDriftWatch/);
  assert.match(html, /__cvDriftWatch = window\.setInterval\(\(\) => \{[\s\S]{0,220}scheduleResync\(\);/);
  assert.match(html, /if \(document\.visibilityState === 'hidden'\) return;[\s\S]{0,120}if \(searchQuery/);
  assert.match(web, /emitSSEChurnLocked\(onlyIfCooled: true\)/);
  assert.match(web, /emitSSEChurnLocked\(onlyIfCooled: false\)/);
  assert.match(web, /guard churn == 0, lastSSEChurnValue > 0 else \{ return \}/);
  assert.match(web, /emitSSEChurnLocked\(onlyIfCooled: true\)\n\s+let ping/);
});
