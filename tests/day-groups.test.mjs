/**
 * Wall day-grouping gate (Node, no browser).
 *
 * The wall packs one masonry canvas per capture day so a repack stays local to
 * a day, the header can summarize it, and the timeline rail can jump to it.
 * Grouping must never reorder capture time (AGENTS.md · 墙).
 *
 * Pure helpers mirror `window.ClipViewDayGroups` in web/index.html; the rest of
 * the file scans the shipped HTML for the DOM wiring.
 *
 * Run: node --test tests/day-groups.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers/src.mjs';

// --- keep in sync with web/index.html DayGroups object ---
const DayGroups = {
  localDayKey(ms) {
    const n = Number(ms);
    const d = new Date(n);
    if (!Number.isFinite(n) || Number.isNaN(d.getTime())) return 'unknown';
    const p = (v) => String(v).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  },
  normDayKey(raw) {
    const s = String(raw == null ? '' : raw).trim();
    const m = s.match(/^(\d{4})[/-](\d{1,2})[/-](\d{1,2})/);
    if (!m) return 'unknown';
    const p = (v) => String(v).padStart(2, '0');
    return m[1] + '-' + p(Number(m[2])) + '-' + p(Number(m[3]));
  },
  keyForItem(item) {
    if (!item) return 'unknown';
    const byWall = DayGroups.normDayKey(item.timeLocal);
    if (byWall !== 'unknown') return byWall;
    const ts = Number(item.timestamp != null ? item.timestamp : item.ts);
    if (Number.isFinite(ts)) return DayGroups.localDayKey(ts * 1000);
    return 'unknown';
  },
  group(items) {
    const out = [];
    const index = new Map();
    for (const it of items || []) {
      if (!it || it.id == null) continue;
      const day = DayGroups.keyForItem(it);
      let g = index.get(day);
      if (!g) { g = { day, items: [] }; index.set(day, g); out.push(g); }
      g.items.push(it);
    }
    return out;
  },
  stats(items) {
    const byType = Object.create(null);
    let total = 0;
    for (const it of items || []) {
      if (!it) continue;
      total += 1;
      const t = String(it.type || 'other').toLowerCase();
      const bucket = (t === 'html' || t === 'rtf') ? 'rich' : t;
      byType[bucket] = (byType[bucket] || 0) + 1;
    }
    return { total, byType };
  },
  parts(day) {
    const m = String(day || '').match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!m) return null;
    return { y: Number(m[1]), m: Number(m[2]), d: Number(m[3]) };
  },
  addDays(day, delta) {
    const p = DayGroups.parts(day);
    if (!p) return '';
    const dt = new Date(p.y, p.m - 1, p.d + (Number(delta) || 0));
    const pad = (n) => String(n).padStart(2, '0');
    return dt.getFullYear() + '-' + pad(dt.getMonth() + 1) + '-' + pad(dt.getDate());
  },
  weekday(day) {
    const p = DayGroups.parts(day);
    if (!p) return '';
    return '周' + ['日', '一', '二', '三', '四', '五', '六'][new Date(p.y, p.m - 1, p.d).getDay()];
  },
  shortLabel(day, todayKey) {
    if (!day || day === 'unknown') return '更早';
    if (todayKey && day === todayKey) return '今天';
    if (todayKey && day === DayGroups.addDays(todayKey, -1)) return '昨天';
    const p = DayGroups.parts(day);
    if (!p) return day;
    const sameYear = !todayKey || todayKey.slice(0, 4) === day.slice(0, 4);
    return (sameYear ? '' : p.y + '年') + p.m + '月' + p.d + '日';
  },
  railLabel(day, todayKey) {
    if (!day || day === 'unknown') return '更早';
    if (todayKey && day === todayKey) return '今天';
    if (todayKey && day === DayGroups.addDays(todayKey, -1)) return '昨天';
    const p = DayGroups.parts(day);
    if (!p) return day;
    if (todayKey && todayKey.slice(0, 4) !== day.slice(0, 4)) return p.y + '/' + p.m + '/' + p.d;
    return p.m + '/' + p.d;
  },
  dayDateText(day) {
    const p = DayGroups.parts(day);
    if (!p) return '';
    const pad = (n) => String(n).padStart(2, '0');
    const wd = DayGroups.weekday(day);
    return p.y + '/' + pad(p.m) + '/' + pad(p.d) + (wd ? ' ' + wd : '');
  },
};

const html = readFileSync(join(root, 'web/index.html'), 'utf8');

test('keyForItem prefers the server wall clock over client TZ math', () => {
  assert.equal(DayGroups.keyForItem({ timeLocal: '2026/10/10 23:59:01' }), '2026-10-10');
  // ISO also normalizes.
  assert.equal(DayGroups.keyForItem({ timeLocal: '2026-10-09T08:00:00' }), '2026-10-09');
  // Timestamp fallback (seconds) when the server wall string is absent (head frames).
  const ms = new Date(2026, 9, 8, 12, 0, 0).getTime();
  assert.equal(DayGroups.keyForItem({ timestamp: ms / 1000 }), '2026-10-08');
  assert.equal(DayGroups.keyForItem(null), 'unknown');
  assert.equal(DayGroups.keyForItem({}), 'unknown');
});

test('group keeps newest-first order and merges the same day', () => {
  const items = [
    { id: 'a', timeLocal: '2026/10/10 12:00:00' },
    { id: 'b', timeLocal: '2026/10/10 09:00:00' },
    { id: 'c', timeLocal: '2026/10/09 22:00:00' },
    { id: 'd', timeLocal: '2026/10/09 01:00:00' },
    { id: 'e', timeLocal: '2026/10/01 01:00:00' },
  ];
  const groups = DayGroups.group(items);
  assert.deepEqual(groups.map((g) => g.day), ['2026-10-10', '2026-10-09', '2026-10-01']);
  assert.deepEqual(groups[0].items.map((i) => i.id), ['a', 'b']);
  assert.deepEqual(groups[1].items.map((i) => i.id), ['c', 'd']);
  assert.deepEqual(groups[2].items.map((i) => i.id), ['e']);
});

test('stats totals and collapses html/rtf into one rich bucket', () => {
  const st = DayGroups.stats([
    { type: 'image' }, { type: 'image' }, { type: 'text' },
    { type: 'html' }, { type: 'rtf' }, { type: 'url' },
  ]);
  assert.equal(st.total, 6);
  assert.equal(st.byType.image, 2);
  assert.equal(st.byType.text, 1);
  assert.equal(st.byType.url, 1);
  assert.equal(st.byType.rich, 2);
});

test('today / yesterday / older labels', () => {
  const today = '2026-10-10';
  assert.equal(DayGroups.shortLabel('2026-10-10', today), '今天');
  assert.equal(DayGroups.shortLabel('2026-10-09', today), '昨天');
  assert.equal(DayGroups.shortLabel('2026-10-01', today), '10月1日');
  assert.equal(DayGroups.shortLabel('2025-12-31', today), '2025年12月31日');
  assert.equal(DayGroups.shortLabel('unknown', today), '更早');
  // Rail omits the year for the current year, keeps it otherwise.
  assert.equal(DayGroups.railLabel('2026-10-01', today), '10/1');
  assert.equal(DayGroups.railLabel('2025-12-31', today), '2025/12/31');
});

test('dayDateText carries the weekday and pads', () => {
  // 2024-01-01 was a Monday.
  assert.equal(DayGroups.dayDateText('2024-01-01'), '2024/01/01 周一');
  assert.equal(DayGroups.dayDateText('bad'), '');
});

test('addDays crosses month and year boundaries', () => {
  assert.equal(DayGroups.addDays('2026-03-01', -1), '2026-02-28');
  assert.equal(DayGroups.addDays('2024-03-01', -1), '2024-02-29');
  assert.equal(DayGroups.addDays('2025-12-31', 1), '2026-01-01');
});

test('shipped wall groups by day and exposes a timeline rail', () => {
  assert.match(html, /window\.ClipViewDayGroups = DayGroups;/);
  assert.match(html, /<div id="grid" class="wall-feed"/);
  assert.match(html, /<nav id="dayRail" class="day-rail"/);
  assert.match(html, /function dayHeadMarkup\(group\)/);
  assert.match(html, /class="day-title"/);
  assert.match(html, /class="day-stat is-total"/);
  assert.match(html, /function ensureDaySection\(feed, day\)/);
  assert.match(html, /function reconcileDaySections\(feed, groups\)/);
  assert.match(html, /function renderDayRail\(groups\)/);
  assert.match(html, /function jumpToDay\(day\)/);
  assert.match(html, /data-day-jump=/);
  assert.match(html, /\.day-rail-btn\.is-active/);
});

test('incremental paths reuse the day canvas and only repack that day', () => {
  // Append / prepend must create the day host, not call the old single canvas.
  assert.match(html, /function relayoutDays\(days, \{ preserveScroll = true \} = \{\}\)/);
  assert.match(html, /function relayoutAllDays\(/);
  // Rail visibility changes feed width, so it forces a full (day-aware) reflow.
  assert.match(html, /if \(renderDayRail\(DayGroups\.group\(wallRestItems\(\)\)\)\) \{ rebuildFromData\(\{ preserveScroll: true \}\);/);
  // Degenerate detection walks each day canvas when handed the feed container.
  assert.match(html, /el\.querySelectorAll\(':scope > \.day-group > \.day-masonry'\)/);
  // Day canvas keeps its class (layoutMasonry adds `masonry`, never overwrites).
  assert.match(html, /host\.classList\.add\('masonry'\);/);
});

test('timeline jump is a budgeted metric', () => {
  assert.match(html, /nm\('wall_day_jump'/);
  assert.match(html, /wall_day_jump: \{ label: '时间线跳转'/);
});
