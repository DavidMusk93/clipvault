/**
 * Operations drawer gate (Node, no browser).
 *
 * The drawer is a *reading* of `operation_logs`, so what can silently break is not
 * pixels but the reading:
 *
 *   1. chart shape must follow the data — no duration samples means an explicit
 *      boundary, not an axis pretending there is nothing to see (docs/design-taste.md
 *      · 图表选型);
 *   2. aggregate JSON keys must stay in step with `OpsAnalytics.json` (the panel and
 *      the Swift aggregate are edited in different languages);
 *   3. the page must not fetch or parse anything until the drawer is opened, and a
 *      fresh aggregate must not be re-fetched on every open.
 *
 * Run: node --test tests/oplog-panel.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers/src.mjs';

import {
  BURST_RATIO, DEFAULT_WINDOW, ROW_LIMIT, STALE_MS, WINDOWS, aggregateTail, chartPlan, fmtGap,
  fmtMs, mountOpsPanel, pct, renderReport, renderRows, sourceKey, sourceLabel, windowSeconds,
} from '../web/assets/oplog-panel.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const swift = readFileSync(join(root, 'Sources/ClipVault/Store/OpsAnalytics.swift'), 'utf8');
const server = readFileSync(join(root, 'Sources/ClipVault/HTTP/WebServer.swift'), 'utf8');

let JSDOM = null;
try {
  ({ JSDOM } = await import('jsdom'));
} catch {
  JSDOM = null;
}
const domSkip = JSDOM ? false : 'jsdom not installed — run `npm ci`';

// --- fixtures ---------------------------------------------------------------

/** An aggregate shaped exactly like `OpsAnalytics.json`. */
function report(over = {}) {
  return {
    window: { since: 0, now: 1, zone: 'Asia/Shanghai', bucket: 'day', bucketSeconds: 86400 },
    total: 131,
    durN: 120,
    firstTs: 1,
    peakBucket: { t: 3, label: '10-14', n: 120 },
    medianGap: 30,
    longestGap: 7200,
    silentDays: [],
    buckets: [
      { t: 1, label: '10-13', n: 0, bySource: {} },
      { t: 2, label: '10-14', n: 120, bySource: { web: 120 } },
      { t: 3, label: '10-15', n: 11, bySource: { backup: 11 } },
    ],
    actions: [
      { action: 'compose_edit', n: 120, items: 3, share: 120 / 131, firstTs: 1, lastTs: 2, durN: 120, p50: 10, p95: 19, max: 20, avg: 10.5 },
      { action: 'backup', n: 11, items: 0, share: 11 / 131, firstTs: 1, lastTs: 3, durN: 11, p50: 120, p95: 5000, max: 5200, avg: 1000 },
    ],
    sources: [
      { source: 'web', n: 120, actions: 1, share: 120 / 131 },
      { source: 'backup', n: 11, actions: 1, share: 11 / 131 },
    ],
    signals: [
      { id: 'oplog_firehose', severity: 'med', text: 'compose_edit 占全部操作 92%', action: '降频', now: 0.92, target: 0.4, unit: 'ratio' },
      { id: 'oplog_slow', severity: 'med', text: 'backup p95 5.00s，超过预算 2.00s', action: '对照 p95', now: 5000, target: 2000, unit: 'ms' },
    ],
    ...over,
  };
}

// --- formatters -------------------------------------------------------------

test('window mapping mirrors the server windows', () => {
  assert.deepEqual(WINDOWS.map((w) => w.key), ['24h', '7d', '30d', '90d']);
  assert.equal(windowSeconds('24h'), 86400);
  assert.equal(windowSeconds('90d'), 90 * 86400);
  assert.equal(windowSeconds('nonsense'), windowSeconds(DEFAULT_WINDOW));
  assert.equal(DEFAULT_WINDOW, '7d');
});

test('durations never render as 5.00kms', () => {
  assert.equal(fmtMs(0.4), '0.4ms');
  assert.equal(fmtMs(19), '19ms');
  assert.equal(fmtMs(999), '999ms');
  assert.equal(fmtMs(1000), '1.00s');
  assert.equal(fmtMs(5000), '5.00s');
  assert.equal(fmtMs(null), '—');
  assert.equal(fmtGap(30), '30 秒');
  assert.equal(fmtGap(600), '10 分');
  assert.equal(fmtGap(7200), '2.0 小时');
  assert.equal(fmtGap(2 * 86400), '2.0 天');
  assert.equal(pct(0.924), '92%');
});

test('source aliases share the design-taste palette', () => {
  assert.equal(sourceKey('sync:sunmingqiangdemacbook-6c56ee13'), 'sync');
  assert.equal(sourceKey('maintenance'), 'maintenance');
  assert.equal(sourceKey('purge-cron'), 'maintenance');
  assert.equal(sourceKey('clipboard'), 'clipboard');
  assert.equal(sourceKey(''), 'system');
  assert.equal(sourceLabel('sync:abc'), '同步');
});

// --- shape follows the data -------------------------------------------------

test('a short series is refused instead of drawn as a trend', () => {
  const two = chartPlan(report({ buckets: [{ t: 1, label: '10-14', n: 5, bySource: {} }] }));
  assert.equal(two.series.kind, 'none');
  assert.match(two.series.note, /1–2 个时间点/);
  const none = chartPlan(report({ buckets: [] }));
  assert.equal(none.series.kind, 'none');
  assert.match(none.series.note, /没有任何操作记录/);
  assert.equal(chartPlan(report()).series.kind, 'columns');
});

test('the peak bucket is flagged only when the burst budget fired', () => {
  const noBurst = report({ signals: [{ id: 'oplog_ok', severity: 'good', text: 'ok', action: '保持', now: 0, target: 0, unit: 'count' }] });
  assert.equal(chartPlan(noBurst).series.rows.filter((r) => r.flag).length, 0);
  const burst = report({ signals: [{ id: 'oplog_burst', severity: 'med', text: 'x', action: 'y', now: 24, target: BURST_RATIO, unit: 'ratio' }] });
  const flags = chartPlan(burst).series.rows.filter((r) => r.flag);
  assert.equal(flags.length, 1);
  assert.equal(flags[0].label, '10-14');
  assert.equal(BURST_RATIO, 6);
});

test('no duration samples is a boundary, not an empty axis', () => {
  const noDur = report({
    durN: 0,
    actions: [{ action: 'reader.comment', n: 11, items: 3, share: 1, firstTs: 1, lastTs: 2, durN: 0, p50: null, p95: null, max: null, avg: null }],
  });
  const plan = chartPlan(noDur);
  assert.equal(plan.durations.rows.length, 0);
  assert.match(plan.durations.note, /没有任何耗时采样/);
  assert.match(plan.durations.note, /dur_ms/);
  // …and nothing is invented: a null p95 never becomes a 0ms bar.
  assert.equal(renderReport(noDur).includes('0ms'), false);
});

test('duration ranking is sorted by p95 and carries n/max', () => {
  const rows = chartPlan(report()).durations.rows;
  assert.deepEqual(rows.map((r) => r.label), ['backup', 'compose_edit']);
  assert.equal(rows[0].value, 5000);
  assert.match(rows[0].sub, /n=11 · max 5\.20s/);
});

test('global operations do not claim "0 个目标"', () => {
  const out = renderReport(report());
  assert.equal(out.includes('0 个目标'), false);
  assert.match(out, /8\.4%/); // the share still rides along with the bar
});

test('long rankings fold the tail instead of truncating silently', () => {
  const many = Array.from({ length: 20 }, (_, i) => ({ label: `a${i}`, value: 20 - i }));
  const folded = aggregateTail(many, 12, '动作');
  assert.equal(folded.length, 13);
  assert.match(folded[12].label, /其它 8 个动作/);
  assert.equal(folded[12].value, 8 + 7 + 6 + 5 + 4 + 3 + 2 + 1);
  // short lists are untouched
  assert.equal(aggregateTail([{ label: 'x', value: 1 }], 12, '动作').length, 1);
});

// --- the reading ------------------------------------------------------------

test('the report renders all four channels plus budgeted signals', () => {
  const out = renderReport(report());
  // KPIs
  for (const label of ['总操作', '类型', '峰值时段', '中位间隔', '最长空档', '耗时样本']) {
    assert.ok(out.includes(label), `missing KPI ${label}`);
  }
  // signals carry the number that justifies them (now -> target, one unit)
  assert.match(out, /sev-med/);
  assert.match(out, /92%/);
  assert.match(out, /5\.00s → 2\.00s/);
  // charts
  assert.match(out, /mc-cols/);      // time series
  assert.match(out, /mc-bars/);      // type ranking + duration ranking
  assert.match(out, /mc-stack-track/); // source composition
  // sections in reading order
  const order = ['问题信号', '时间序列', '操作类型排行', '耗时 p95', '来源构成', '<h3 class="ops-h3">明细'];
  let at = -1;
  for (const h of order) {
    const i = out.indexOf(h);
    assert.ok(i > at, `${h} out of order`);
    at = i;
  }
  assert.ok(out.indexOf('id="opsRows"') > at, 'the ledger sits under the charts');
  // every type row is a drill-down target
  assert.match(out, /data-jump="compose_edit"/);
  assert.match(out, new RegExp(`最近 ${ROW_LIMIT} 条`));
});

test('a filtered reading marks the selection and offers a way out', () => {
  const out = renderReport(report(), { selectedAction: 'backup', rows: [] });
  assert.match(out, /data-jump="backup" aria-pressed="true"/);
  assert.match(out, /清除筛选（backup）/);
  assert.match(out, /没有匹配的记录/);
});

const WINDOWS_LABEL = html.includes('ops-windows');

test('rows escape content and carry the source rail', () => {
  const out = renderRows([
    { action: 'web_archive', source: 'sync:peer2', durMs: 1234, itemId: 'abcdef01-2345', detail: '<img src=x onerror=alert(1)>', timeLocal: '2026/10/15 13:00:00' },
  ]);
  assert.match(out, /ops-src-sync/);
  assert.match(out, /1\.23s/);
  assert.match(out, /abcdef01/);
  assert.match(out, /2026\/10\/15 13:00:00/);
  // detail is text, never markup
  assert.equal(out.includes('<img'), false);
  assert.match(out, /&lt;img/);
  // no duration sample -> no duration chip at all (not "0ms")
  assert.equal(renderRows([{ action: 'pin', source: 'web', durMs: null }]).includes('ops-dur'), false);
});

// --- page wiring ------------------------------------------------------------

test('the wall page loads the drawer lazily, on open', () => {
  assert.match(html, /id="opsDrawer"/);
  assert.match(html, /data-ui-zone="ops"/);
  assert.match(html, /id="opsToolbar"/);
  assert.ok(WINDOWS_LABEL, 'window chips have their own container');
  // module + chart skin are imported on demand, not in <head>
  assert.match(html, /import\('\/assets\/oplog-panel\.mjs/);
  assert.match(html, /mine-charts\.css/);
  assert.equal(/<script[^>]+oplog-panel\.mjs/.test(html), false, 'no eager script tag');
  assert.equal(/<link[^>]+mine-charts\.css/.test(html), false, 'no eager stylesheet');
  // the aggregate is the default read; raw rows need a drill-down
  assert.match(html, /api\/oplogs\/stats\?window=/);
  assert.match(html, /api\/oplogs\?' \+ p\.toString\(\)/);
  // the old "one card per operation" census is gone
  assert.equal(html.includes("refreshOpLogs"), false);
  assert.equal(html.includes('ops-item'), false);
  assert.equal(html.includes("/api/oplogs?limit=300"), false);
  // endpoints exist server-side
  assert.match(server, /pathOnly == "\/api\/oplogs\/stats"/);
});

test('aggregate keys stay in step with the Swift report', () => {
  const jsonBlock = swift.slice(swift.indexOf('static func json(_ report: Report) -> [String: Any]'));
  const keys = new Set([...jsonBlock.matchAll(/^\s*"([a-z][A-Za-z]*)":/gm)].map((m) => m[1]));
  for (const key of ['window', 'total', 'durN', 'peakBucket', 'medianGap', 'longestGap', 'silentDays', 'buckets', 'actions', 'sources', 'signals']) {
    assert.ok(keys.has(key), `OpsAnalytics.json lost key ${key}`);
  }
  // window / bucket / action / source field names the panel reads
  for (const field of ['bySource', 'bucketSeconds', 'firstTs', 'lastTs', 'firstLocal', 'lastLocal', 'durN', 'p50', 'p95', 'max', 'avg', 'items', 'share']) {
    assert.ok(jsonBlock.includes(`"${field}"`), `aggregate lost ${field}`);
  }
  // signals must keep the machine-checkable half
  for (const field of ['id', 'severity', 'text', 'action', 'now', 'target', 'unit']) {
    assert.ok(jsonBlock.includes(`"${field}"`), `signal lost ${field}`);
  }
  // the panel's own reading of the payload
  for (const read of ['report.window', 'buckets', 'actions', 'sources', 'signals', 'peakBucket', 'medianGap', 'longestGap', 'silentDays', 'durN']) {
    assert.ok(readFileSync(join(root, 'web/assets/oplog-panel.mjs'), 'utf8').includes(read), `panel stopped reading ${read}`);
  }
});

// --- mount behaviour --------------------------------------------------------

test('mount fetches only on open, and a fresh aggregate is not re-fetched', { skip: domSkip }, async () => {
  const dom = new JSDOM('<!doctype html><html><body><span id="tb"></span><div id="view"></div></body></html>');
  const { document } = dom.window;
  let stats = 0;
  let rows = 0;
  let clock = 1000;
  const panel = mountOpsPanel({
    root: document.getElementById('view'),
    toolbar: document.getElementById('tb'),
    now: () => clock,
    fetchStats: async () => { stats += 1; return report(); },
    fetchRows: async () => { rows += 1; return { items: [{ action: 'pin', source: 'web', ts: 1 }] }; },
  });

  assert.equal(stats, 0, 'mount must not fetch');
  assert.equal(panel._state().windowKey, DEFAULT_WINDOW);
  // window chips are built at mount, from the shared table
  const chips = [...document.querySelectorAll('[data-ops-window]')];
  assert.deepEqual(chips.map((c) => c.getAttribute('data-ops-window')), ['24h', '7d', '30d', '90d']);
  assert.equal(chips[1].getAttribute('aria-pressed'), 'true');

  panel.open();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(stats, 1);
  assert.match(document.getElementById('view').innerHTML, /总操作/);

  // reopening inside the freshness window paints from cache
  panel.open();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(stats, 1, 'fresh aggregate must not be refetched');
  clock += STALE_MS + 1;
  panel.open();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(stats, 2, 'stale aggregate revalidates in the background');

  // an explicit refresh always refetches
  panel.refresh();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(stats, 3);
  assert.equal(rows, 0, 'raw rows are never fetched by a refresh');

  // drill-down: clicking a type filters rows in SQL, not in the DOM
  document.querySelector('[data-jump="backup"]').dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true }));
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(rows, 1);
  assert.equal(panel._state().selectedAction, 'backup');
  assert.match(document.getElementById('opsRows').innerHTML, /ops-src-web/);

  // clicking the same type again clears the filter
  document.querySelector('[data-jump="backup"]').dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true }));
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(panel._state().selectedAction, '');

  // switching window resets the drill-down and refetches
  document.querySelector('[data-ops-window="90d"]').dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true }));
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(panel._state().windowKey, '90d');
  assert.equal(stats, 4);
  panel.open();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(stats, 4, 'after a window switch the fresh copy is reused');
});

test('a failed aggregate surfaces instead of painting a half-truth', { skip: domSkip }, async () => {
  const dom = new JSDOM('<!doctype html><html><body><span id="tb2"></span><div id="view2"></div></body></html>');
  const { document } = dom.window;
  let errs = 0;
  const panel = mountOpsPanel({
    root: document.getElementById('view2'),
    toolbar: document.getElementById('tb2'),
    fetchStats: async () => { throw new Error('boom'); },
    fetchRows: async () => ({ items: [] }),
    onError: () => { errs += 1; },
  });
  panel.open();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(errs, 1);
  assert.match(document.getElementById('view2').innerHTML, /加载中/);
});
