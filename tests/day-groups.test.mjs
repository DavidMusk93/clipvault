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

const html = readFileSync(join(root, 'web/index.html'), 'utf8');

/**
 * The shipped pure object, evaluated out of the page: a hand-kept copy of the
 * header/day math is exactly how a lazy wall ends up printing numbers nobody
 * can reproduce. The oracle lives in the assertions below.
 */
const DayGroups = new Function(
  `${html.slice(html.indexOf('const DayGroups = {'), html.indexOf('window.ClipViewDayGroups = DayGroups;'))}\nreturn DayGroups;`,
)();

assert.ok(typeof DayGroups?.keyForItem === 'function', 'DayGroups must stay exported on window');

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

test('collapseTypes buckets the store aggregate the same way as a loaded slice', () => {
  // The server ships raw types; the header bucket rule lives here, once.
  const collapsed = DayGroups.collapseTypes({ html: 3, rtf: 2, image: 1, IMAGE: 4, note: 1 });
  assert.equal(collapsed.rich, 5);
  assert.equal(collapsed.image, 5);
  assert.equal(collapsed.note, 1);
  assert.deepEqual(DayGroups.collapseTypes({}), Object.create(null));
  assert.deepEqual(DayGroups.collapseTypes(undefined), Object.create(null));
  // Both paths must agree, or a header would change when the index lands.
  const items = [{ type: 'html' }, { type: 'rtf' }, { type: 'image' }];
  const raw = { html: 1, rtf: 1, image: 1 };
  assert.deepEqual(DayGroups.stats(items).byType, DayGroups.collapseTypes(raw));
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
  assert.match(html, /function dayHeadMarkup\(group, serverStats = null\)/);
  assert.match(html, /class="day-title"/);
  assert.match(html, /class="day-stat is-total\$\{partial \? ' is-partial' : ''\}"/);
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
