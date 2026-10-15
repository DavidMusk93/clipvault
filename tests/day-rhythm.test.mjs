/**
 * Wall day-rhythm gate (Node, no browser).
 *
 * Each day header carries the day's own activity strip: 288 five-minute marks on
 * the **capture clock** (`timeLocal`, else unix seconds) plus four facts
 * (活跃跨度 / 峰值 / 夜间占比 / 最长空档). Marks must come from capture time, so
 * OCR, sync arrival and hydration can never move them (AGENTS.md · 墙).
 *
 * The numbers themselves no longer come from painted cards: the header reads the
 * store's day aggregate (`/api/clips/days` → `DayRhythm.normalize`), and
 * `DayRhythm.summary(items)` is only the fallback for the loaded slice. This gate
 * evaluates the **shipped** `DayRhythm` out of `web/index.html` and compares it
 * against an independent minute-based oracle, so the two can never drift.
 *
 * Run: node --test tests/day-rhythm.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');

/** The shipped pure object, evaluated out of the page (no hand-kept copy). */
function shippedDayRhythm() {
  const start = html.indexOf('const DayRhythm = {');
  assert.ok(start > 0, 'DayRhythm object missing from web/index.html');
  const end = html.indexOf('window.ClipViewDayRhythm = DayRhythm;', start);
  assert.ok(end > start, 'DayRhythm must stay exported on window');
  return new Function(`${html.slice(start, end)}\nreturn DayRhythm;`)();
}

const DayRhythm = shippedDayRhythm();

// --- independent oracle: minutes in, facts out ------------------------------
const BINS = 288;
const WINDOW_BINS = 6;      // 峰值 = the busiest 30 minutes
const NIGHT_START = 22 * 60;
const NIGHT_END = 6 * 60;

function minuteOf(item) {
  const wall = String(item?.timeLocal ?? '');
  const m = wall.match(/^(\d{4})[/-](\d{1,2})[/-](\d{1,2})[ T](\d{1,2}):(\d{2})/);
  if (m) {
    const h = Number(m[4]);
    const mi = Number(m[5]);
    if (h >= 0 && h < 24 && mi >= 0 && mi < 60) return h * 60 + mi;
    return null;
  }
  const ts = Number(item?.timestamp);
  if (Number.isFinite(ts) && ts > 0) {
    const d = new Date(ts * 1000);
    return d.getHours() * 60 + d.getMinutes();
  }
  return null;
}

function oracle(items) {
  const minutes = [];
  for (const it of items) {
    const m = minuteOf(it);
    if (m != null) minutes.push(m);
  }
  minutes.sort((a, b) => a - b);
  const bins = new Array(BINS).fill(0);
  for (const m of minutes) bins[Math.min(BINS - 1, Math.floor(m / 5))] += 1;
  let maxBin = 0;
  for (const b of bins) if (b > maxBin) maxBin = b;
  let peakBin = 0;
  let peakCount = 0;
  // Independent of the bins: the busiest wall-clock half hour, counted in minutes.
  for (let start = 0; start < 24 * 60; start += WINDOW_BINS * 5) {
    let sum = 0;
    for (const m of minutes) if (m >= start && m < start + WINDOW_BINS * 5) sum += 1;
    if (sum > peakCount) { peakCount = sum; peakBin = start / 5; }
  }
  let night = 0;
  for (const m of minutes) if (m >= NIGHT_START || m < NIGHT_END) night += 1;
  let maxGapMin = null;
  let gapFromMin = null;
  let gapToMin = null;
  for (let i = 1; i < minutes.length; i += 1) {
    const gap = minutes[i] - minutes[i - 1];
    if (maxGapMin == null || gap > maxGapMin) { maxGapMin = gap; gapFromMin = minutes[i - 1]; gapToMin = minutes[i]; }
  }
  return {
    bins,
    maxBin,
    total: items.length,
    n: minutes.length,
    firstMin: minutes.length ? minutes[0] : null,
    lastMin: minutes.length ? minutes[minutes.length - 1] : null,
    peakBin,
    peakCount,
    night,
    maxGapMin,
    gapFromMin,
    gapToMin,
  };
}

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

const day = (h, m, s = 0) => ({ timeLocal: `2026/10/10 ${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` });
/** Six captures: 09:12/09:20 · 14:02/14:07/14:29 · 23:10 (used by the band tests). */
const gapDayItems = () => [day(9, 12), day(9, 20), day(14, 2), day(14, 7), day(14, 29), day(23, 10)];

test('the shipped strip reads five-minute marks', () => {
  assert.equal(DayRhythm.BINS, 288);
  assert.equal(DayRhythm.BIN_MINUTES, 5);
  assert.equal(DayRhythm.PEAK_BINS, WINDOW_BINS);
  assert.equal(DayRhythm.BINS * DayRhythm.BIN_MINUTES, 24 * 60);
  assert.match(html, /const DayRhythm = \{\n      BINS: 288,\n      BIN_MINUTES: 5,/);
});

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

test('histogram buckets five minutes and skips unusable times', () => {
  const { bins, n } = DayRhythm.histogram([
    day(0, 0), day(0, 29, 59), day(0, 30), day(23, 59),
    { timeLocal: '2026/10/10' }, {},
  ]);
  assert.equal(bins.length, 288);
  assert.equal(n, 4);
  assert.equal(bins[0], 1);
  assert.equal(bins[5], 1);   // 00:25–00:30
  assert.equal(bins[6], 1);   // 00:30–00:35
  assert.equal(bins[287], 1);
  assert.equal(bins.reduce((a, b) => a + b, 0), 4);
});

test('summary matches a minute-based oracle (span, peak window, night, gap)', () => {
  for (const items of [gapDayItems(), [day(8, 0)], [], [day(0, 0), day(0, 4), day(0, 5), day(23, 59)]]) {
    const s = DayRhythm.summary(items);
    const o = oracle(items);
    assert.equal(s.n, o.n);
    assert.equal(s.total, o.total);
    assert.equal(s.firstMin, o.firstMin);
    assert.equal(s.lastMin, o.lastMin);
    assert.equal(s.spanMin, o.firstMin == null ? 0 : o.lastMin - o.firstMin);
    assert.deepEqual(s.bins, o.bins);
    assert.equal(s.maxBin, o.maxBin);
    assert.equal(s.peakBin, o.peakBin);
    assert.equal(s.peakCount, o.peakCount);
    assert.equal(s.night, o.night);
    assert.equal(s.nightShare, o.n ? o.night / o.n : 0);
    assert.equal(s.maxGapMin, o.maxGapMin);
    assert.equal(s.gapFromMin, o.gapFromMin);
    assert.equal(s.gapToMin, o.gapToMin);
  }
});

test('the six-clip day still reads the same facts it did at half-hour resolution', () => {
  const s = DayRhythm.summary(gapDayItems());
  assert.equal(s.n, 6);
  assert.equal(s.firstMin, 9 * 60 + 12);
  assert.equal(s.lastMin, 23 * 60 + 10);
  assert.equal(s.spanMin, (23 * 60 + 10) - (9 * 60 + 12));
  // The busiest 30 minutes are 14:00–14:30 (14:02/14:07/14:29) → mark 168.
  assert.equal(s.peakBin, 168);
  assert.equal(s.peakCount, 3);
  assert.equal(DayRhythm.peakLabel(s), '14:00–14:30 · 3 条');
  assert.equal(s.night, 1);
  assert.ok(Math.abs(s.nightShare - 1 / 6) < 1e-9);
  // 14:29 → 23:10 is the longest break (09:20 → 14:02 is 282 min).
  assert.equal(s.maxGapMin, (23 * 60 + 10) - (14 * 60 + 29));
});

test('峰值 is a wall-clock half hour, so a lone mark cannot win it', () => {
  const bins = new Array(288).fill(0);
  bins[100] = 3;                       // one busy five-minute mark (08:20–08:25)
  bins[200] = 1; bins[201] = 1; bins[202] = 1; bins[203] = 1;   // a busier half hour
  const s = DayRhythm.normalize({ bins, total: 7, timed: 7, night: 0, firstMin: 500, lastMin: 1015 });
  assert.equal(s.maxBin, 3);
  assert.equal(s.peakBin, 198);   // 16:30–17:00
  assert.equal(s.peakCount, 4);
  assert.equal(DayRhythm.peakLabel(s), '16:30–17:00 · 4 条');
  assert.deepEqual(DayRhythm.peakRange(s), { from: 198, to: 204 });
  // The window never drifts off :00/:30 to hug its marks.
  const lone = DayRhythm.normalize({ bins: Object.assign(new Array(288).fill(0), { 100: 2 }), total: 2, timed: 2, night: 0, firstMin: 500, lastMin: 502 });
  assert.equal(DayRhythm.peakLabel(lone), '08:00–08:30 · 2 条');
  // Ties keep the earliest window (deterministic, never "some mark").
  const tie = DayRhythm.normalize({ bins: new Array(288).fill(1), total: 288, timed: 288, night: 0, firstMin: 0, lastMin: 1439 });
  assert.equal(tie.peakBin, 0);
  assert.equal(tie.peakCount, 6);
});

test('night window is 22:00-05:59 and is inclusive of nothing else', () => {
  assert.equal(DayRhythm.isNight(5 * 60 + 59), true);
  assert.equal(DayRhythm.isNight(6 * 60), false);
  assert.equal(DayRhythm.isNight(21 * 60 + 59), false);
  assert.equal(DayRhythm.isNight(22 * 60), true);
  assert.equal(DayRhythm.isNight(null), false);
});

test('a day with one clip has a span but no gap; an empty day is safe', () => {
  const one = DayRhythm.summary([day(8, 0)]);
  assert.equal(one.spanMin, 0);
  assert.equal(one.maxGapMin, null);
  assert.equal(one.peakBin, 96);   // 08:00–08:05
  assert.equal(one.peakCount, 1);
  assert.equal(one.nightShare, 0);
  const empty = DayRhythm.summary([]);
  assert.equal(empty.n, 0);
  assert.equal(empty.total, 0);
  assert.equal(empty.firstMin, null);
  assert.equal(empty.nightShare, 0);
  assert.equal(empty.maxGapMin, null);
  assert.equal(DayRhythm.summary(undefined).n, 0);
  assert.equal(DayRhythm.peakLabel(empty), '—');
});

test('normalize takes the store aggregate as-is and never invents numbers', () => {
  const bins = new Array(288).fill(0);
  bins[110] = 1; bins[112] = 1;
  const s = DayRhythm.normalize({
    day: '2026/10/10', total: 4103, timed: 4100, bins, night: 37,
    firstMin: 359, lastMin: 1390, maxGapMin: 521, gapFromMin: 869, gapToMin: 1390,
    byType: { image: 4000 },
  });
  assert.equal(s.total, 4103);           // the store's count, not sum(bins)
  assert.equal(s.n, 4100);
  assert.equal(s.night, 37);
  assert.equal(s.firstMin, 359);
  assert.equal(s.spanMin, 1031);
  assert.equal(s.maxGapMin, 521);
  assert.equal(s.gapFromMin, 869);
  assert.equal(s.nightShare, 37 / 4100);
  assert.deepEqual(s.bins.length, 288);
  // Missing/blank optional fields stay null instead of becoming 0-o'clock.
  const thin = DayRhythm.normalize({ bins: new Array(288).fill(0), firstMin: null, lastMin: null });
  assert.equal(thin.firstMin, null);
  assert.equal(thin.lastMin, null);
  assert.equal(thin.maxGapMin, null);
  assert.equal(thin.spanMin, 0);
  assert.equal(DayRhythm.normalize(null).total, 0);
  assert.equal(DayRhythm.normalize(undefined).n, 0);
});

test('labels format like the rest of the wall (tabular hh:mm, Chinese duration)', () => {
  assert.equal(DayRhythm.hhmm(0), '00:00');
  assert.equal(DayRhythm.hhmm(14 * 60 + 5), '14:05');
  assert.equal(DayRhythm.hhmm(24 * 60), '24:00');
  assert.equal(DayRhythm.hhmm(NaN), '—');
  assert.equal(DayRhythm.binLabel(0), '00:00–00:05');
  assert.equal(DayRhythm.binLabel(287), '23:55–24:00');
  assert.equal(DayRhythm.duration(0), '0 分');
  assert.equal(DayRhythm.duration(28), '28 分');
  assert.equal(DayRhythm.duration(60), '1 小时');
  assert.equal(DayRhythm.duration(9 * 60 + 28), '9 小时 28 分');
});

test('binOf maps a minute of day onto the five-minute marks', () => {
  assert.equal(DayRhythm.binOf(0), 0);
  assert.equal(DayRhythm.binOf(4), 0);
  assert.equal(DayRhythm.binOf(5), 1);
  assert.equal(DayRhythm.binOf(14 * 60), 168);
  assert.equal(DayRhythm.binOf(23 * 60 + 59), 287);
  // 24:00 is the right edge of the last mark, not a 289th one.
  assert.equal(DayRhythm.binOf(24 * 60), 287);
  assert.equal(DayRhythm.binOf(null), null);
  assert.equal(DayRhythm.binOf(undefined), null);
  assert.equal(DayRhythm.binOf('14:00'), null);
});

test('fact bands stay five-minute honest: the gap band never covers a mark with clips', () => {
  const s = DayRhythm.summary(gapDayItems());
  assert.equal(s.gapFromMin, 14 * 60 + 29);
  assert.equal(s.gapToMin, 23 * 60 + 10);
  // span = first..last mark inclusive (09:12 mark 110 .. 23:10 mark 278)
  assert.deepEqual(DayRhythm.markBins(s, 'span'), { from: 110, to: 279 });
  // peak = the whole busiest half hour (14:00–14:30 → marks 168..174, half-open)
  assert.deepEqual(DayRhythm.markBins(s, 'peak'), { from: 168, to: 174 });
  const gap = DayRhythm.markBins(s, 'gap');
  assert.deepEqual(gap, { from: 174, to: 278 });
  for (let i = gap.from; i < gap.to; i += 1) {
    assert.equal(s.bins[i], 0, `gap band must skip mark ${i} (it has clips)`);
  }
  assert.ok(s.bins[gap.from - 1] > 0 && s.bins[gap.to] > 0, 'the clipping marks bound the band');
  // A break shorter than one mark collapses to a zero-width tick, never onto clips.
  const short = DayRhythm.summary([day(10, 0), day(10, 5)]);
  assert.deepEqual(DayRhythm.markBins(short, 'gap'), { from: 121, to: 121 });
  // One clip: one mark of span, nothing to mark as a gap.
  const one = DayRhythm.summary([day(8, 0)]);
  assert.deepEqual(DayRhythm.markBins(one, 'span'), { from: 96, to: 97 });
  assert.equal(DayRhythm.markBins(one, 'gap'), null);
  // No usable capture time: no bands at all (the header still renders the box).
  const empty = DayRhythm.summary([]);
  for (const kind of ['span', 'peak', 'gap']) assert.equal(DayRhythm.markBins(empty, kind), null);
});

test('the scrub readout reads one mark; the peak fact reads its window', () => {
  assert.equal(DayRhythm.binReadout({ bin: 210, count: 7, total: 44, peak: true }), '17:30–17:35 · 7 条 · 占 16% · 峰值');
  assert.equal(DayRhythm.binReadout({ bin: 0, count: 0, total: 44 }), '00:00–00:05 · 0 条 · 占 0%');
  assert.equal(DayRhythm.binReadout({ bin: 168, count: 3, total: 6, peak: true, window: 6 }), '14:00–14:30 · 3 条 · 占 50% · 峰值');
  // No day total (or none usable) → no invented share.
  assert.equal(DayRhythm.binReadout({}), '00:00–00:05 · 0 条');
  assert.equal(DayRhythm.binReadout({ bin: 999, count: 1, total: 0 }), '23:55–24:00 · 1 条');
  assert.equal(DayRhythm.binReadout({ bin: -3, count: 2, total: 4 }), '00:00–00:05 · 2 条 · 占 50%');
  // A window never runs past midnight.
  assert.equal(DayRhythm.binReadout({ bin: 286, count: 2, total: 4, window: 6 }), '23:50–24:00 · 2 条 · 占 50%');
});

test('shipped header renders the rhythm strip and keeps the old anchors', () => {
  assert.match(html, /window\.ClipViewDayRhythm = DayRhythm;/);
  assert.match(html, /function dayRhythmMarkup\(rhythm, \{ today = false, nowMin = null, partial = false \} = \{\}\)/);
  assert.match(html, /class="day-rhythm\$\{partialCls\}" data-day-rhythm/);
  assert.match(html, /class="day-head-top"/);
  assert.match(html, /class="rhythm-track" role="slider" tabindex="0" data-rhythm-track/);
  assert.match(html, /const cls = 'rhythm-bar'/);
  assert.match(html, /inPeak \? ' is-peak' : ''/);
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
  assert.match(html, /class="day-stat is-total/);
  // Days without a usable capture time still render the box, never a broken grid.
  assert.match(html, /class="rhythm-fact-value">无时间</);
  // A no-time day has nothing to scrub, so it stays a plain image.
  assert.match(html, /class="rhythm-track" role="img" aria-label="当天没有可用捕获时间"/);
});

test('the day head reads the store aggregate, and says so when it has none', () => {
  const body = fnBody('dayHeadMarkup');
  // Numbers come from the day index, never from the painted cards.
  assert.match(body, /const partial = !serverStats;/);
  assert.match(body, /const total = partial \? local\.total : Math\.max\(0, Number\(serverStats\.total\) \|\| 0\);/);
  assert.match(body, /DayGroups\.collapseTypes\(serverStats\.byType\)/);
  assert.match(body, /DayRhythm\.normalize\(serverStats\)/);
  // The fallback is honest: a lower bound, no type pills, a marker class.
  assert.match(body, /const pills = partial \? '' :/);
  assert.match(body, /is-total\$\{partial \? ' is-partial' : ''\}/);
  assert.match(body, /\$\{partial \? '&#8805; ' : ''\}/);
  assert.doesNotMatch(body, /DayGroups\.stats\(group\.items\)\) \?\?/);
});

test('scrub reads one mark and never re-flows the wall', () => {
  // The crosshair / readout / bands are overlays: hover must not move the wall.
  assert.match(html, /\.rhythm-guide \{[\s\S]{0,260}position: absolute;/);
  // The crosshair must move on the compositor (transform), never on `left`.
  assert.match(html, /guide\.style\.transform = 'translateX\(' \+ \(frac \* rect\.width\)\.toFixed\(2\) \+ 'px\)'/);
  assert.match(html, /\.day-rhythm\.is-scrub \.rhythm-guide \{ will-change: transform; \}/);
  assert.doesNotMatch(html, /guide\.style\.left/);
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

test('the scrub is keyboard reachable and announces the mark it reads', () => {
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
  assert.match(html, /\{ today, nowMin: today \? wallNowMinute\(\) : null, partial \}/);
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
  // The fallback head dims instead of recolouring.
  assert.match(html, /\.day-rhythm\.is-partial \.rhythm-track,/);
  assert.match(html, /\.day-stat\.is-partial \{ color: var\(--muted\); \}/);
});
