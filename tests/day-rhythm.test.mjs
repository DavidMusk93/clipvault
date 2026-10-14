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
  binOf(min) {
    if (min == null || min === '') return null;
    const v = Number(min);
    if (!Number.isFinite(v)) return null;
    return Math.max(0, Math.min(DayRhythm.BINS - 1, Math.floor(Math.max(0, v) / DayRhythm.BIN_MINUTES)));
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
    let gapFrom = null;
    let gapTo = null;
    for (let i = 1; i < minutes.length; i += 1) {
      const gap = minutes[i] - minutes[i - 1];
      if (gap > maxGapMin) { maxGapMin = gap; gapFrom = minutes[i - 1]; gapTo = minutes[i]; }
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
      gapFromMin: minutes.length > 1 ? gapFrom : null,
      gapToMin: minutes.length > 1 ? gapTo : null,
    };
  },
  markBins(s, kind) {
    if (!s || !s.n) return null;
    if (kind === 'peak') {
      return s.peakCount ? { from: s.peakBin, to: s.peakBin + 1 } : null;
    }
    if (kind === 'span') {
      if (s.firstMin == null) return null;
      return { from: DayRhythm.binOf(s.firstMin), to: DayRhythm.binOf(s.lastMin) + 1 };
    }
    if (kind === 'gap') {
      if (s.gapFromMin == null) return null;
      const from = DayRhythm.binOf(s.gapFromMin) + 1;
      const to = DayRhythm.binOf(s.gapToMin);
      return to <= from ? { from, to: from } : { from, to };
    }
    return null;
  },
  binReadout({ bin = 0, count = 0, total = 0, peak = false } = {}) {
    const i = Math.max(0, Math.min(DayRhythm.BINS - 1, Math.floor(Number(bin) || 0)));
    const n = Math.max(0, Number(count) || 0);
    const parts = [DayRhythm.binLabel(i), n + ' 条'];
    if (Number(total) > 0) parts.push('占 ' + Math.round((n / Number(total)) * 100) + '%');
    if (peak) parts.push('峰值');
    return parts.join(' · ');
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

/** Body of a top-level function in the shipped inline script (brace matched). */
function fnBody(name) {
  const m = new RegExp(`function ${name}\\b`).exec(html);
  assert.ok(m, `missing function ${name}`);
  const start = html.indexOf('{', m.index);
  assert.ok(start > 0, `missing body for ${name}`);
  let depth = 0;
  for (let i = start; i < html.length; i += 1) {
    if (html[i] === '{') depth += 1;
    else if (html[i] === '}') {
      depth -= 1;
      if (depth === 0) return html.slice(m.index, i + 1);
    }
  }
  return html.slice(m.index, start + 4000);
}

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

// A six-clip day used by the band + readout tests: 09:12/09:20 · 14:02/14:07/14:29 · 23:10
const gapDayItems = () => [
  { timeLocal: '2026/10/10 09:12:00' },
  { timeLocal: '2026/10/10 09:20:00' },
  { timeLocal: '2026/10/10 14:02:00' },
  { timeLocal: '2026/10/10 14:07:00' },
  { timeLocal: '2026/10/10 14:29:00' },
  { timeLocal: '2026/10/10 23:10:00' },
];

test('binOf maps a minute of day onto the 48 half-hour marks', () => {
  assert.equal(DayRhythm.binOf(0), 0);
  assert.equal(DayRhythm.binOf(29), 0);
  assert.equal(DayRhythm.binOf(30), 1);
  assert.equal(DayRhythm.binOf(14 * 60), 28);
  assert.equal(DayRhythm.binOf(23 * 60 + 59), 47);
  // 24:00 is the right edge of the last mark, not a 49th one.
  assert.equal(DayRhythm.binOf(24 * 60), 47);
  assert.equal(DayRhythm.binOf(null), null);
  assert.equal(DayRhythm.binOf(undefined), null);
  assert.equal(DayRhythm.binOf('14:00'), null);
});

test('fact bands stay half-hour honest: the gap band never covers a bin with clips', () => {
  const s = DayRhythm.summary(gapDayItems());
  assert.equal(s.gapFromMin, 14 * 60 + 29);
  assert.equal(s.gapToMin, 23 * 60 + 10);
  // span = first..last bin inclusive (09:12 bin 18 .. 23:10 bin 46)
  assert.deepEqual(DayRhythm.markBins(s, 'span'), { from: 18, to: 47 });
  // peak = the one bin that holds the most clips (14:00–14:30), half-open
  assert.deepEqual(DayRhythm.markBins(s, 'peak'), { from: 28, to: 29 });
  const gap = DayRhythm.markBins(s, 'gap');
  assert.deepEqual(gap, { from: 29, to: 46 });
  for (let i = gap.from; i < gap.to; i += 1) {
    assert.equal(s.bins[i], 0, `gap band must skip bin ${i} (it has clips)`);
  }
  assert.ok(s.bins[gap.from - 1] > 0 && s.bins[gap.to] > 0, 'the clipping bins bound the band');
  // A break shorter than one mark collapses to a zero-width tick, never onto clips.
  const short = DayRhythm.summary([
    { timeLocal: '2026/10/10 10:00:00' },
    { timeLocal: '2026/10/10 10:05:00' },
  ]);
  assert.deepEqual(DayRhythm.markBins(short, 'gap'), { from: 21, to: 21 });
  // One clip: one mark of span, nothing to mark as a gap.
  const one = DayRhythm.summary([{ timeLocal: '2026/10/10 08:00:00' }]);
  assert.deepEqual(DayRhythm.markBins(one, 'span'), { from: 16, to: 17 });
  assert.equal(DayRhythm.markBins(one, 'gap'), null);
  // No usable capture time: no bands at all (the header still renders the box).
  const empty = DayRhythm.summary([]);
  for (const kind of ['span', 'peak', 'gap']) assert.equal(DayRhythm.markBins(empty, kind), null);
});

test('the scrub readout speaks the same facts vocabulary as the row above', () => {
  assert.equal(DayRhythm.binReadout({ bin: 35, count: 7, total: 44, peak: true }), '17:30–18:00 · 7 条 · 占 16% · 峰值');
  assert.equal(DayRhythm.binReadout({ bin: 0, count: 0, total: 44 }), '00:00–00:30 · 0 条 · 占 0%');
  // No day total (or none usable) → no invented share.
  assert.equal(DayRhythm.binReadout({}), '00:00–00:30 · 0 条');
  assert.equal(DayRhythm.binReadout({ bin: 999, count: 1, total: 0 }), '23:30–24:00 · 1 条');
  assert.equal(DayRhythm.binReadout({ bin: -3, count: 2, total: 4 }), '00:00–00:30 · 2 条 · 占 50%');
});

test('shipped header renders the rhythm strip and keeps the old anchors', () => {
  assert.match(html, /window\.ClipViewDayRhythm = DayRhythm;/);
  assert.match(html, /function dayRhythmMarkup\(rhythm, \{ today = false, nowMin = null \} = \{\}\)/);
  assert.match(html, /const rhythm = DayRhythm\.summary\(group\.items\);/);
  assert.match(html, /class="day-rhythm" data-day-rhythm/);
  assert.match(html, /class="day-head-top"/);
  assert.match(html, /class="rhythm-track" role="slider" tabindex="0" data-rhythm-track/);
  assert.match(html, /const cls = 'rhythm-bar'/);
  assert.match(html, /is-peak/);
  assert.match(html, /class="rhythm-nightzone"/);
  assert.match(html, /class="rhythm-ticks"/);
  assert.match(html, /class="rhythm-fact-label"/);
  assert.match(html, /class="rhythm-fact-value"/);
  assert.match(html, /data-day-rhythm-facts/);
  assert.match(html, /class="rhythm-facts-list"/);
  assert.match(html, /class="rhythm-guide" aria-hidden="true"/);
  assert.match(html, /data-rhythm-readout/);
  // The pre-existing header contract must survive the extra row.
  assert.match(html, /class="day-title"/);
  assert.match(html, /class="day-date"/);
  assert.match(html, /class="day-stat is-total"/);
  // Days without a usable capture time still render the box, never a broken grid.
  assert.match(html, /class="rhythm-fact-value">无时间</);
  // A no-time day has nothing to scrub, so it stays a plain image.
  assert.match(html, /class="rhythm-track" role="img" aria-label="当天没有可用捕获时间"/);
});

test('scrub reads one bin and never re-flows the wall', () => {
  // The crosshair / readout / bands are overlays: hover must not move the wall.
  assert.match(html, /\.rhythm-guide \{[\s\S]{0,200}position: absolute;/);
  assert.match(html, /\.rhythm-readout \{[\s\S]{0,400}position: absolute;/);
  assert.match(html, /\.rhythm-mark \{[\s\S]{0,300}position: absolute;/);
  assert.match(html, /\.day-rhythm\.is-scrub \.rhythm-facts-list \{ opacity: 0; \}/);
  // Bars own no hit area and no native tooltip: the track is the only target.
  assert.match(html, /\.rhythm-bar \{[\s\S]{0,320}pointer-events: none;/);
  assert.match(html, /data-bin="\$\{i\}" data-n="\$\{count\}"/);
  assert.doesNotMatch(html, /data-bin="\$\{i\}"[^>]*title=/);
  // Neither the paint nor the event path may rebuild cards / masonry.
  const path = fnBody('rhythmPaint') + fnBody('rhythmScrubAt') + fnBody('rhythmReset');
  assert.doesNotMatch(path, /layoutMasonry|rebuildFromData|prependCardsIncremental|innerHTML/);
  // One write per frame, delegated listeners, and one ui_interact per scrub.
  assert.match(html, /requestAnimationFrame\(rhythmPaint\)/);
  assert.match(html, /document\.addEventListener\('pointermove'/);
  assert.match(html, /document\.addEventListener\('pointerover'/);
  assert.match(html, /track\('wall', 'scrub', 'rhythm-track', \{ via \}\)/);
  assert.doesNotMatch(html, /setInterval\([^)]*rhythm/);
});

test('hovering a fact marks only the band it names', () => {
  // One band per fact, resolved at build time from the same half-open bin math.
  assert.match(html, /function dayRhythmBand\(rhythm, kind\) \{/);
  assert.match(html, /const span = DayRhythm\.markBins\(rhythm, 'span'\);/);
  assert.match(html, /const inSpan = !!span && i >= span\.from && i < span\.to;/);
  assert.match(html, /inSpan \? ' is-in-span' : ''/);
  assert.match(html, /data-rhythm-mark="\$\{kind\}"/);
  // Exactly one band is visible at a time; night has no band (static zones).
  assert.match(html, /\.day-rhythm\.is-mark-span \.rhythm-mark-span,/);
  assert.match(html, /\.day-rhythm\.is-mark-gap \.rhythm-mark-gap \{ opacity: 1; \}/);
  assert.match(html, /\.day-rhythm\.is-mark-span \.rhythm-bar:not\(\.is-in-span\) \{ opacity: 0\.45; \}/);
  assert.match(html, /\.day-rhythm\.is-mark-peak \.rhythm-bar:not\(\.is-peak\) \{ opacity: 0\.45; \}/);
  assert.match(html, /\.day-rhythm\.is-mark-night \.rhythm-nightzone \{ background: rgba\(196, 122, 44, 0\.16\); \}/);
  assert.match(html, /kind === 'night' \|\| dayRhythmBand\(rhythm, kind\)/);
  // Bands are neutral honey / the same grey the night zones use — no new hue.
  assert.match(html, /\.rhythm-mark-span \{ background: rgba\(196, 122, 44, 0\.16\); \}/);
  assert.match(html, /\.rhythm-mark-gap \{ background: rgba\(60, 60, 67, 0\.16\); \}/);
});

test('the scrub is keyboard reachable and announces the bin it reads', () => {
  assert.match(html, /aria-valuemin="0" aria-valuemax="\$\{DayRhythm\.BINS - 1\}"/);
  assert.match(html, /aria-valuenow="\$\{rhythm\.peakBin\}" aria-valuetext="\$\{escAttr\(readout\)\}"/);
  assert.match(html, /aria-valuetext", text\)|setAttribute\('aria-valuetext', text\)/);
  assert.match(html, /ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1/);
  assert.match(html, /ev\.key === 'Home'/);
  assert.match(html, /ev\.key === 'End'/);
  assert.match(html, /ev\.preventDefault\(\);\s+\/\/ arrows scrub, they must not scroll the wall/);
  assert.match(html, /\.rhythm-track\[data-rhythm-track\]:focus-visible/);
});

test('the now marker is today-only, built once (no timer repaint)', () => {
  assert.match(html, /const now = today && nowMin != null/);
  assert.match(html, /\{ today, nowMin: today \? wallNowMinute\(\) : null \}/);
  assert.match(html, /function wallNowMinute\(\)/);
  assert.doesNotMatch(html, /setInterval\([^)]*wallNowMinute/);
  assert.doesNotMatch(html, /setInterval\([^)]*dayRhythmMarkup/);
});

test('day pills reuse the card type source (no raw latin bucket in a Chinese header)', () => {
  // One truth for labels/icons/colours: the header must not keep a second map
  // that drifts (it used to print `note` instead of 笔记).
  assert.match(html, /function dayBucketMeta\(bucket\) \{\n      if \(bucket === 'rich'\) return \{ label: '富文本', icon: 'code', cls: 'type-html' \};\n      return typeMeta\(bucket\);/);
  assert.doesNotMatch(html, /bucket === 'other' \? '其他' : String\(bucket \|\| ''\)/);
});

test('the strip stays one honey hue (no second colour, no rainbow)', () => {
  assert.match(html, /\.rhythm-bar\.is-peak \{ background: var\(--type-text\); \}/);
  assert.match(html, /\.rhythm-bar \{[\s\S]{0,220}background: rgba\(196, 122, 44, 0\.26\);/);
  assert.match(html, /\.rhythm-bar\.is-night \{ background: rgba\(196, 122, 44, 0\.15\); \}/);
  // Marks are sized by height, so counts never need a new colour.
  assert.match(html, /height: var\(--h, 2px\)/);
  assert.doesNotMatch(html, /\.rhythm-bar[^}]*linear-gradient/);
});
