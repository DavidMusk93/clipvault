/**
 * Wall day-rhythm gate (Node, no browser).
 *
 * Each day header carries the day's own activity strip: 48 half-hour marks on
 * the **capture clock** (`timeLocal`, else unix seconds) plus four facts
 * (活跃跨度 / 峰值 / 夜间占比 / 最长空档). Marks must come from capture time, so
 * OCR, sync arrival and hydration can never move them (AGENTS.md · 墙).
 *
 * Pure helpers mirror `window.ClipViewDayRhythm` in web/index.html; the rest of
 * the file scans the shipped HTML for the DOM wiring and the design tokens.
 *
 * Run: node --test tests/day-rhythm.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers/src.mjs';

// --- keep in sync with web/index.html DayRhythm object ---
const DayRhythm = {
  BINS: 48,
  BIN_MINUTES: 30,
  NIGHT_START: 22 * 60,
  NIGHT_END: 6 * 60,
  minuteOfItem(item) {
    if (!item) return null;
    const wall = String(item.timeLocal == null ? '' : item.timeLocal).trim();
    if (/^\d{4}[/-]\d{1,2}[/-]\d{1,2}[ T]/.test(wall)) {
      const m = wall.match(/(\d{1,2}):(\d{2})(?::\d{2})?/);
      if (m) {
        const h = Number(m[1]);
        const mi = Number(m[2]);
        if (h >= 0 && h < 24 && mi >= 0 && mi < 60) return h * 60 + mi;
      }
    }
    const ts = Number(item.timestamp != null ? item.timestamp : item.ts);
    if (Number.isFinite(ts) && ts > 0) {
      const d = new Date(ts * 1000);
      if (!Number.isNaN(d.getTime())) return d.getHours() * 60 + d.getMinutes();
    }
    return null;
  },
  isNight(min) {
    if (min == null || min === '') return false;
    const m = Number(min);
    return Number.isFinite(m) && (m >= DayRhythm.NIGHT_START || m < DayRhythm.NIGHT_END);
  },
  histogram(items) {
    const bins = new Array(DayRhythm.BINS).fill(0);
    let n = 0;
    for (const it of items || []) {
      const m = DayRhythm.minuteOfItem(it);
      if (m == null) continue;
      bins[Math.min(DayRhythm.BINS - 1, Math.floor(m / DayRhythm.BIN_MINUTES))] += 1;
      n += 1;
    }
    return { bins, n };
  },
  summary(items) {
    const { bins, n } = DayRhythm.histogram(items);
    const minutes = [];
    for (const it of items || []) {
      const m = DayRhythm.minuteOfItem(it);
      if (m != null) minutes.push(m);
    }
    minutes.sort((a, b) => a - b);
    let peakBin = 0;
    let peakCount = 0;
    for (let i = 0; i < bins.length; i += 1) {
      if (bins[i] > peakCount) { peakCount = bins[i]; peakBin = i; }
    }
    let night = 0;
    for (const m of minutes) if (DayRhythm.isNight(m)) night += 1;
    let maxGapMin = 0;
    for (let i = 1; i < minutes.length; i += 1) {
      const gap = minutes[i] - minutes[i - 1];
      if (gap > maxGapMin) maxGapMin = gap;
    }
    const firstMin = minutes.length ? minutes[0] : null;
    const lastMin = minutes.length ? minutes[minutes.length - 1] : null;
    return {
      bins,
      n,
      total: (items || []).length,
      firstMin,
      lastMin,
      spanMin: firstMin == null ? 0 : lastMin - firstMin,
      peakBin,
      peakCount,
      night,
      nightShare: n ? night / n : 0,
      maxGapMin: minutes.length > 1 ? maxGapMin : null,
    };
  },
  hhmm(min) {
    const v = Number(min);
    if (!Number.isFinite(v)) return '—';
    const clamped = Math.max(0, Math.min(24 * 60, Math.round(v)));
    const p = (x) => String(x).padStart(2, '0');
    return p(Math.floor(clamped / 60)) + ':' + p(clamped % 60);
  },
  duration(min) {
    const v = Math.max(0, Math.round(Number(min) || 0));
    const h = Math.floor(v / 60);
    const m = v % 60;
    if (!h) return m + ' 分';
    return m ? h + ' 小时 ' + m + ' 分' : h + ' 小时';
  },
  binLabel(i) {
    const start = (Number(i) || 0) * DayRhythm.BIN_MINUTES;
    return DayRhythm.hhmm(start) + '–' + DayRhythm.hhmm(start + DayRhythm.BIN_MINUTES);
  },
};

const html = readFileSync(join(root, 'web/index.html'), 'utf8');

test('minuteOfItem reads the capture wall clock, not the browser TZ or sync time', () => {
  assert.equal(DayRhythm.minuteOfItem({ timeLocal: '2026/10/10 14:05:09' }), 14 * 60 + 5);
  // ISO wall string (server fallback shape) also parses.
  assert.equal(DayRhythm.minuteOfItem({ timeLocal: '2026-10-10T09:30:00' }), 9 * 60 + 30);
  // Unix seconds fallback (head frames omit timeLocal) — local zone, same as DayGroups.
  const local = new Date(2026, 9, 10, 23, 40, 0).getTime() / 1000;
  assert.equal(DayRhythm.minuteOfItem({ timestamp: local }), 23 * 60 + 40);
  assert.equal(DayRhythm.minuteOfItem(null), null);
  assert.equal(DayRhythm.minuteOfItem({}), null);
  assert.equal(DayRhythm.minuteOfItem({ timeLocal: '2026/10/10' }), null);
  assert.equal(DayRhythm.minuteOfItem({ timeLocal: '2026/10/10 25:00:00' }), null);
});

test('histogram buckets half-hours and skips unusable times', () => {
  const { bins, n } = DayRhythm.histogram([
    { timeLocal: '2026/10/10 00:00:00' },
    { timeLocal: '2026/10/10 00:29:59' },
    { timeLocal: '2026/10/10 00:30:00' },
    { timeLocal: '2026/10/10 23:59:00' },
    { timeLocal: '2026/10/10' },
    {},
  ]);
  assert.equal(bins.length, 48);
  assert.equal(n, 4);
  assert.equal(bins[0], 2);
  assert.equal(bins[1], 1);
  assert.equal(bins[47], 1);
  assert.equal(bins.reduce((a, b) => a + b, 0), 4);
});

test('summary reports span, peak, night share and longest gap', () => {
  const s = DayRhythm.summary([
    { timeLocal: '2026/10/10 09:12:00' },
    { timeLocal: '2026/10/10 09:20:00' },
    { timeLocal: '2026/10/10 14:02:00' },
    { timeLocal: '2026/10/10 14:07:00' },
    { timeLocal: '2026/10/10 14:29:00' },
    { timeLocal: '2026/10/10 23:10:00' },
  ]);
  assert.equal(s.n, 6);
  assert.equal(s.total, 6);
  assert.equal(s.firstMin, 9 * 60 + 12);
  assert.equal(s.lastMin, 23 * 60 + 10);
  assert.equal(s.spanMin, (23 * 60 + 10) - (9 * 60 + 12));
  assert.equal(s.peakBin, 28); // 14:00–14:30
  assert.equal(s.peakCount, 3);
  assert.equal(s.night, 1);
  assert.ok(Math.abs(s.nightShare - 1 / 6) < 1e-9);
  // 14:29 -> 23:10 is the longest break (09:20 -> 14:02 is 282 min).
  assert.equal(s.maxGapMin, (23 * 60 + 10) - (14 * 60 + 29));
});

test('night window is 22:00-05:59 and is inclusive of nothing else', () => {
  assert.equal(DayRhythm.isNight(5 * 60 + 59), true);
  assert.equal(DayRhythm.isNight(6 * 60), false);
  assert.equal(DayRhythm.isNight(21 * 60 + 59), false);
  assert.equal(DayRhythm.isNight(22 * 60), true);
  assert.equal(DayRhythm.isNight(null), false);
});

test('a day with one clip has a span but no gap; an empty day is safe', () => {
  const one = DayRhythm.summary([{ timeLocal: '2026/10/10 08:00:00' }]);
  assert.equal(one.spanMin, 0);
  assert.equal(one.maxGapMin, null);
  assert.equal(one.peakBin, 16); // 08:00–08:30
  assert.equal(one.nightShare, 0);
  const empty = DayRhythm.summary([]);
  assert.equal(empty.n, 0);
  assert.equal(empty.total, 0);
  assert.equal(empty.firstMin, null);
  assert.equal(empty.nightShare, 0);
  assert.equal(empty.maxGapMin, null);
  assert.equal(DayRhythm.summary(undefined).n, 0);
});

test('labels format like the rest of the wall (tabular hh:mm, Chinese duration)', () => {
  assert.equal(DayRhythm.hhmm(0), '00:00');
  assert.equal(DayRhythm.hhmm(14 * 60 + 5), '14:05');
  assert.equal(DayRhythm.hhmm(24 * 60), '24:00');
  assert.equal(DayRhythm.hhmm(NaN), '—');
  assert.equal(DayRhythm.binLabel(0), '00:00–00:30');
  assert.equal(DayRhythm.binLabel(47), '23:30–24:00');
  assert.equal(DayRhythm.duration(0), '0 分');
  assert.equal(DayRhythm.duration(28), '28 分');
  assert.equal(DayRhythm.duration(60), '1 小时');
  assert.equal(DayRhythm.duration(9 * 60 + 28), '9 小时 28 分');
});

test('shipped header renders the rhythm strip and keeps the old anchors', () => {
  assert.match(html, /window\.ClipViewDayRhythm = DayRhythm;/);
  assert.match(html, /function dayRhythmMarkup\(rhythm, \{ today = false, nowMin = null \} = \{\}\)/);
  assert.match(html, /const rhythm = DayRhythm\.summary\(group\.items\);/);
  assert.match(html, /class="day-rhythm" data-day-rhythm/);
  assert.match(html, /class="day-head-top"/);
  assert.match(html, /class="rhythm-track" role="img"/);
  assert.match(html, /const cls = 'rhythm-bar'/);
  assert.match(html, /is-peak/);
  assert.match(html, /class="rhythm-nightzone"/);
  assert.match(html, /class="rhythm-ticks"/);
  assert.match(html, /class="rhythm-fact-label"/);
  assert.match(html, /class="rhythm-fact-value"/);
  assert.match(html, /data-day-rhythm-facts/);
  // The pre-existing header contract must survive the extra row.
  assert.match(html, /class="day-title"/);
  assert.match(html, /class="day-date"/);
  assert.match(html, /class="day-stat is-total"/);
  // Days without a usable capture time still render the box, never a broken grid.
  assert.match(html, /class="rhythm-fact-value">无时间</);
});

test('the now marker is today-only, built once (no timer repaint)', () => {
  assert.match(html, /const now = today && nowMin != null/);
  assert.match(html, /\{ today, nowMin: today \? wallNowMinute\(\) : null \}/);
  assert.match(html, /function wallNowMinute\(\)/);
  assert.doesNotMatch(html, /setInterval\([^)]*wallNowMinute/);
  assert.doesNotMatch(html, /setInterval\([^)]*dayRhythmMarkup/);
});

test('the strip stays one honey hue (no second colour, no rainbow)', () => {
  assert.match(html, /\.rhythm-bar\.is-peak \{ background: var\(--type-text\); \}/);
  assert.match(html, /\.rhythm-bar \{[\s\S]{0,220}background: rgba\(196, 122, 44, 0\.26\);/);
  assert.match(html, /\.rhythm-bar\.is-night \{ background: rgba\(196, 122, 44, 0\.15\); \}/);
  // Marks are sized by height, so counts never need a new colour.
  assert.match(html, /height: var\(--h, 2px\)/);
  assert.doesNotMatch(html, /\.rhythm-bar[^}]*linear-gradient/);
});
