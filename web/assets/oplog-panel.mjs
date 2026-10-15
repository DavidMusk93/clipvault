/**
 * Operations drawer — reading surface for `operation_logs`.
 *
 * One card per operation is a census: 10831 `compose_edit` cards look exactly like
 * 11 `reader.comment` cards, so nothing is visible until you scroll. This module
 * turns the store's aggregate (`GET /api/oplogs/stats`, computed in
 * `OpsAnalytics.swift`) into the four channels that show a problem — type,
 * frequency, duration, time series — plus budgeted signals, and keeps the raw rows
 * as a drill-down instead of the default view.
 *
 * Two hard rules:
 *   1. Charts only say what the data supports (chartPlan): no duration samples means
 *      an explicit boundary, not an empty axis.
 *   2. Nothing is fetched until the drawer is opened, and the aggregate is painted
 *      from cache while a stale copy revalidates in the background.
 *
 * `renderReport` / `renderRows` / `chartPlan` are pure string builders, so
 * `tests/oplog-panel.test.mjs` can pin the reading and the shape selection without
 * a browser. Colours come from the shared chart palette
 * (`web/assets/mine-charts.mjs`) and the ops source table in docs/design-taste.md.
 */

import { columns, rankBars, stackBar } from './mine-charts.mjs';

export const WINDOWS = [
  { key: '24h', label: '24 小时', seconds: 24 * 3600 },
  { key: '7d', label: '7 天', seconds: 7 * 86400 },
  { key: '30d', label: '30 天', seconds: 30 * 86400 },
  { key: '90d', label: '90 天', seconds: 90 * 86400 },
];

export const DEFAULT_WINDOW = '7d';
/** Mirror of OpsAnalytics.Budget.burstRatio — only used to flag the peak bucket. */
export const BURST_RATIO = 6;
/** Aggregate is fresh enough to paint without revalidating. */
export const STALE_MS = 30_000;
export const ROW_LIMIT = 50;

export function windowSeconds(key) {
  const w = WINDOWS.find((x) => x.key === key);
  return w ? w.seconds : WINDOWS[1].seconds;
}

const esc = (s) =>
  String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

export const fmtCount = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return '—';
  // Ratios such as saves-per-target arrive fractional; one decimal, never "80.577".
  return Number.isInteger(v) ? v.toLocaleString('en-US') : v.toFixed(1);
};

/** Wall time of one operation. Same rule as the shared chart formatter. */
export function fmtMs(ms) {
  // A missing sample is "—", never "0ms": a NULL dur_ms means "not instrumented".
  if (ms == null || ms === '') return '—';
  const n = Number(ms);
  if (!Number.isFinite(n)) return '—';
  if (n >= 1000) return `${(n / 1000).toFixed(2)}s`;
  if (n >= 10) return `${Math.round(n)}ms`;
  return `${n.toFixed(1)}ms`;
}

export function fmtGap(seconds) {
  const n = Number(seconds);
  if (!Number.isFinite(n) || n < 0) return '—';
  if (n >= 86400) return `${(n / 86400).toFixed(1)} 天`;
  if (n >= 3600) return `${(n / 3600).toFixed(1)} 小时`;
  if (n >= 60) return `${Math.round(n / 60)} 分`;
  return `${Math.round(n)} 秒`;
}

export const pct = (v) => `${(Number(v) * 100).toFixed(Number(v) * 100 >= 10 ? 0 : 1)}%`;

/** Alias table for `operation_logs.source` -> palette key (docs/design-taste.md). */
export function sourceKey(source) {
  const s = String(source || 'system').toLowerCase().trim();
  if (['web', 'clipboard', 'backup', 'maintenance', 'app', 'sync', 'system'].includes(s)) return s;
  if (s.startsWith('sync')) return 'sync';
  if (s.includes('web') || s.includes('ui')) return 'web';
  if (s.includes('clip')) return 'clipboard';
  if (s.includes('back')) return 'backup';
  if (s.includes('maint') || s.includes('purge') || s.includes('cron')) return 'maintenance';
  if (s.includes('app')) return 'app';
  return 'system';
}

export const SOURCE_LABEL = {
  web: '网页',
  clipboard: '剪贴板',
  backup: '备份',
  maintenance: '维护',
  app: '应用',
  sync: '同步',
  system: '系统',
};

export const sourceLabel = (s) => SOURCE_LABEL[sourceKey(s)] || sourceKey(s);

/** Top N rows, with the tail folded into one labelled row. Never silent truncation. */
export function aggregateTail(rows, limit = 12, label = '名称') {
  const list = rows || [];
  if (list.length <= limit) return list.slice();
  const head = list.slice(0, limit);
  const tail = list.slice(limit);
  head.push({
    label: `其它 ${tail.length} 个${label}`,
    value: tail.reduce((a, r) => a + (Number(r.value) || 0), 0),
    color: '#8e8e93',
    tail: true,
  });
  return head;
}

export const SOURCE_COLORS = {
  web: '#007aff',
  clipboard: '#34c759',
  backup: '#af52de',
  maintenance: '#ff9500',
  app: '#5856d6',
  sync: '#32ade6',
  system: '#8e8e93',
};

/**
 * Shape follows the data (docs/design-taste.md · 图表选型). Returns descriptors,
 * not HTML, so the page can show a boundary note where a chart would be lying.
 */
export function chartPlan(report) {
  const buckets = (report && report.buckets) || [];
  const actions = (report && report.actions) || [];
  const sources = (report && report.sources) || [];
  const signals = (report && report.signals) || [];

  const burstFired = signals.some((s) => s.id === 'oplog_burst');
  const peak = report && report.peakBucket;
  const series = {
    kind: buckets.length >= 3 ? 'columns' : 'none',
    rows: buckets.map((b) => ({
      label: b.label,
      value: b.n,
      note: Object.entries(b.bySource || {})
        .sort((a, c) => c[1] - a[1])
        .map(([k, v]) => `${sourceLabel(k)} ${v}`)
        .join(' · '),
      flag: Boolean(burstFired && peak && peak.label === b.label && b.n > 0),
    })),
    note:
      buckets.length >= 3
        ? ''
        : buckets.length === 0
          ? '这个窗口没有任何操作记录'
          : '这个窗口只有 1–2 个时间点，画不出趋势',
  };

  const durations = aggregateTail(
    actions
      .filter((a) => Number(a.durN) > 0 && Number.isFinite(Number(a.p95)))
      .sort((a, b) => Number(b.p95) - Number(a.p95))
      .map((a) => ({
        label: a.action,
        value: Number(a.p95),
        sub:
          `n=${a.durN}` +
          (Number(a.max) >= 2 * Number(a.p95) ? ` · max ${fmtMs(a.max)}` : ''),
      })),
    10,
    '动作',
  );

  const durNote = durations.length
    ? ''
    : Number(report && report.total) > 0
      ? '本窗口没有任何耗时采样：只有被计时过的操作才有 dur_ms（backup / web_archive / capture_insert / restore_db 已有）'
      : '这个窗口没有任何操作记录';

  return {
    series,
    actions: {
      rows: aggregateTail(
        actions.map((a) => ({
          label: a.action,
          value: a.n,
          jump: a.action,
          // One derived number, and only when it is not already visible: the count is
          // in the row and the bar, the share is in the signals, and "583 个目标"
          // next to "583" is the same number twice. What a count cannot show is
          // repetition against the same target — that earns the second column
          // (`oplog_repeat` is the same reading, budgeted).
          sub: repeatHint(a.n, a.items),
        })),
        12,
        '动作',
      ),
      empty: actions.length ? '' : '这个窗口没有任何操作类型',
    },
    durations: { rows: durations, note: durNote },
    sources: {
      // Part-to-whole with an exact split: the segmented bar keeps the numbers
      // readable at any count (a pie is capped at 6 slices).
      parts: sources.map((s) => ({
        label: sourceLabel(s.source),
        value: s.n,
        color: SOURCE_COLORS[sourceKey(s.source)],
      })),
    },
  };
}

export const SEV_CLASS = { high: 'sev-high', med: 'sev-med', note: 'sev-note', good: 'sev-good' };

/** Below this, operations are 1:1 with their target and the hint says nothing. */
export const REPEAT_HINT_MIN = 2;

/** `每个目标 N 次`, or nothing — see the note in `chartPlan.actions`. */
export function repeatHint(n, items) {
  const count = Number(n);
  const targets = Number(items);
  if (!Number.isFinite(count) || !Number.isFinite(targets) || targets <= 0) return '';
  const rate = count / targets;
  if (rate < REPEAT_HINT_MIN) return '';
  return `每个目标 ${Math.round(rate)} 次`;
}

function kpi(value, label, hint = '', tone = '') {
  return (
    `<div class="ops-kpi"><b${tone ? ` class="${tone}"` : ''}>${esc(value)}</b><span>${esc(label)}</span>` +
    (hint ? `<em>${esc(hint)}</em>` : '') +
    `</div>`
  );
}

function signalRow(s) {
  const budget =
    s.unit === 'ms'
      ? `${fmtMs(s.now)} → ${fmtMs(s.target)}`
      : s.unit === 'ratio'
        ? `${Number(s.now).toFixed(1)}× → ${s.target}×`
        : s.unit === 's'
          ? `${fmtGap(s.now)} → ${fmtGap(s.target)}`
          : `${fmtCount(s.now)} → ${fmtCount(s.target)}`;
  return (
    `<li class="ops-signal ${SEV_CLASS[s.severity] || 'sev-note'}">` +
    `<div class="ops-signal-h"><span class="ops-signal-dot"></span><span class="ops-signal-txt">${esc(s.text)}</span>` +
    `<span class="ops-signal-budget">${esc(budget)}</span></div>` +
    `<div class="ops-signal-a">${esc(s.action)}</div></li>`
  );
}

/**
 * Pure render of one aggregate report. `state.selectedAction` marks the drill-down
 * filter so the ranking doubles as the selector.
 */
export function renderReport(report, state = {}) {
  if (!report) return '<p class="backup-label">加载中…</p>';
  const plan = chartPlan(report);
  const w = report.window || {};
  const peak = report.peakBucket;

  const kpis = [
    kpi(fmtCount(report.total), '总操作', `${w.bucket === 'hour' ? '每小时' : '每天'}一格`),
    kpi(fmtCount((report.actions || []).length), '类型'),
    kpi(
      peak && peak.n ? `${fmtCount(peak.n)}` : '—',
      '峰值时段',
      peak && peak.n ? peak.label : '',
      't-accent'
    ),
    kpi(fmtGap(report.medianGap), '中位间隔'),
    kpi(fmtGap(report.longestGap), '最长空档'),
    kpi(
      Number(report.durN) > 0 ? fmtCount(report.durN) : '0',
      '耗时样本',
      Number(report.durN) > 0 ? '' : '尚无计时'
    ),
  ].join('');

  const signals = (report.signals || []).map(signalRow).join('');
  const silent = (report.silentDays || []).length
    ? `<div class="ops-extra">无操作日：${esc(report.silentDays.join('、'))}</div>`
    : '';

  const series =
    plan.series.kind === 'columns'
      ? columns(plan.series.rows, {
          title: `操作数 / ${w.bucket === 'hour' ? '小时' : '天'}`,
          total: report.total,
          unit: '',
          axisLeft: plan.series.rows[0].label,
          axisRight: plan.series.rows[plan.series.rows.length - 1].label,
          aria: '操作时间序列',
        }) + (plan.series.rows.some((r) => r.flag) ? '<div class="ops-extra">红点＝本窗口尖峰</div>' : '')
      : `<div class="mc-empty">${esc(plan.series.note)}</div>`;

  const actionsHTML = plan.actions.rows.length
    ? rankBars(plan.actions.rows, {
        unit: '',
        aria: '操作类型排行',
      })
    : `<div class="mc-empty">${esc(plan.actions.empty)}</div>`;
  // The ranking doubles as the drill-down selector, so the chosen row reads as
  // pressed (rankBars has no selection state of its own).
  const actions = state.selectedAction
    ? actionsHTML.replace(`data-jump="${state.selectedAction}"`, `data-jump="${state.selectedAction}" aria-pressed="true"`)
    : actionsHTML;

  const durations = plan.durations.rows.length
    ? rankBars(plan.durations.rows, { unit: 'ms', aria: '操作耗时排行' })
    : `<div class="mc-empty">${esc(plan.durations.note)}</div>`;

  const sources = plan.sources.parts.length
    ? stackBar(plan.sources.parts, { unit: '', total: report.total, aria: '操作来源构成' })
    : '<div class="mc-empty">这个窗口没有任何操作记录</div>';

  const filterNote = state.selectedAction
    ? `<button type="button" class="ops-link" data-ops-clear="1" data-ui="ops-clear">清除筛选（${esc(state.selectedAction)}）</button>`
    : `<button type="button" class="ops-link" data-ops-rows="1" data-ui="ops-rows">最近 ${ROW_LIMIT} 条</button>`;

  return `
    <div class="ops-kpis">${kpis}</div>
    <h3 class="ops-h3">问题信号 <span class="ops-h3-sub">预算 vs 现状</span></h3>
    <ul class="ops-signals">${signals || '<li class="ops-signal sev-note">无信号</li>'}</ul>
    ${silent}
    <h3 class="ops-h3">时间序列</h3>
    <div class="mc-wrap">${series}</div>
    <h3 class="ops-h3">操作类型排行 <span class="ops-h3-sub">点一类看明细</span></h3>
    <div class="mc-wrap">${actions}</div>
    <h3 class="ops-h3">耗时 p95</h3>
    <div class="mc-wrap">${durations}</div>
    <h3 class="ops-h3">来源构成</h3>
    <div class="mc-wrap">${sources}</div>
    <h3 class="ops-h3">明细 <span class="ops-h3-sub" id="opsRowsNote">${esc(
      state.selectedAction ? `筛选 ${state.selectedAction} · 最近 ${ROW_LIMIT} 条` : `最近 ${ROW_LIMIT} 条`
    )}</span></h3>
    <div class="ops-toolbar-row">${filterNote}</div>
    <ul class="ops-rows" id="opsRows">${
      state.rows === null || state.rows === undefined
        ? '<li class="backup-label">点上面任一类，或「最近 50 条」</li>'
        : state.rows.length
          ? ''
          : '<li class="backup-label">没有匹配的记录</li>'
    }</ul>`;
}

/** Pure render of the drill-down rows. Fields pan instead of wrapping. */
export function renderRows(rows) {
  return (rows || [])
    .map((row) => {
      const action = String(row.action ?? '');
      const source = String(row.source ?? 'system');
      const dur = row.durMs == null ? '' : `<span class="ops-dur">${esc(fmtMs(row.durMs))}</span>`;
      const item = row.itemId ? `<span class="ops-id">${esc(String(row.itemId).slice(0, 8))}</span>` : '';
      const detail = row.detail ? `<div class="ops-detail">${esc(String(row.detail))}</div>` : '';
      const time = row.timeLocal || row.ts || '';
      return (
        `<li class="ops-row ops-src-${sourceKey(source)}">` +
        `<div class="ops-row-top"><span class="ops-action">${esc(action)}</span>` +
        `<span class="ops-source-pill">${esc(sourceLabel(source))}</span>${dur}${item}` +
        `<span class="time">${esc(time)}</span></div>${detail}</li>`
      );
    })
    .join('');
}

// ---------------------------------------------------------------------------
// DOM shell: fetch-on-open, cached paint, background revalidation.
// ---------------------------------------------------------------------------

export function mountOpsPanel({ root, toolbar, fetchStats, fetchRows, onError, now = () => Date.now() }) {
  let windowKey = DEFAULT_WINDOW;
  let report = null;
  let reportAt = 0;
  let rows = null;
  let selectedAction = '';
  let loading = false;
  let seq = 0;

  function paint() {
    root.innerHTML = renderReport(report, { selectedAction, rows });
    toolbar.querySelectorAll('[data-ops-window]').forEach((btn) => {
      btn.setAttribute('aria-pressed', String(btn.getAttribute('data-ops-window') === windowKey));
    });
  }

  function paintRows() {
    const host = root.querySelector('#opsRows');
    if (!host) return;
    host.innerHTML = rows && rows.length
      ? renderRows(rows)
      : `<li class="backup-label">${selectedAction ? '没有匹配的记录' : '点上面任一类，或「最近 50 条」'}</li>`;
    const note = root.querySelector('#opsRowsNote');
    if (note) {
      note.textContent = selectedAction
        ? `筛选 ${selectedAction} · 最近 ${ROW_LIMIT} 条`
        : `最近 ${ROW_LIMIT} 条`;
    }
  }

  async function loadStats(force) {
    if (loading) return;
    if (!force && report && now() - reportAt < STALE_MS) return;
    loading = true;
    const mine = ++seq;
    try {
      const data = await fetchStats(windowKey);
      if (mine !== seq) return;
      report = data;
      reportAt = now();
      paint();
      if (rows) paintRows();
    } catch (e) {
      if (mine === seq) onError && onError(e);
    } finally {
      loading = false;
    }
  }

  async function loadRows() {
    rows = [];
    paint();
    try {
      const data = await fetchRows({ action: selectedAction, window: windowKey, limit: ROW_LIMIT });
      rows = (data && data.items) || [];
    } catch (e) {
      rows = [];
      onError && onError(e);
    }
    paintRows();
  }

  function setWindow(key) {
    if (key === windowKey) return;
    windowKey = key;
    selectedAction = '';
    rows = null;
    report = null;
    paint();
    loadStats(true);
  }

  function onClick(ev) {
    const win = ev.target.closest('[data-ops-window]');
    if (win) {
      setWindow(win.getAttribute('data-ops-window'));
      return;
    }
    if (ev.target.closest('[data-ops-clear]')) {
      selectedAction = '';
      rows = null;
      paint();
      return;
    }
    if (ev.target.closest('[data-ops-rows]')) {
      loadRows();
      return;
    }
    const jump = ev.target.closest('[data-jump]');
    if (jump) {
      const next = jump.getAttribute('data-jump');
      selectedAction = selectedAction === next ? '' : next;
      loadRows();
    }
  }

  toolbar.innerHTML = WINDOWS.map(
    (w) =>
      `<button type="button" class="ops-window" data-ops-window="${w.key}" data-ui="ops-window-${w.key}" ` +
      `aria-pressed="false">${esc(w.label)}</button>`
  ).join('');
  toolbar.setAttribute('data-ui-action', 'ops-window');
  // The window chips live in the toolbar and the rankings in the view; one handler
  // serves both (a listener on the view alone would leave the switcher dead).
  root.addEventListener('click', onClick);
  toolbar.addEventListener('click', onClick);
  paint();

  return {
    open() {
      if (!report) paint();
      loadStats(false);
    },
    refresh() {
      loadStats(true);
      if (rows) loadRows();
    },
    setWindow,
    _state: () => ({ windowKey, report, rows, selectedAction }),
  };
}
