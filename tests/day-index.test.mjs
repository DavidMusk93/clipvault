/**
 * Wall day-index gate: the header's numbers must come from the store, not from
 * the cards the lazy wall happens to have painted.
 *
 * Why this is a product gate: `wall` renders a keyset page at a time, so a header
 * that counted painted cards printed 「共 30 条」 for a day with 4103 captures.
 * The fix is not "load the whole day" — it is "ask the store": one
 * `/api/clips/days` aggregate (288 five-minute marks on the capture clock, exact
 * span / night / gap, raw types) backs every header, and the cards only fill the
 * masonry.
 *
 * This file executes the shipped client store (`DayStats` / `fetchDayIndex`)
 * against a stub fetch, renders `dayHeadMarkup` from a store payload and from a
 * loaded slice, and scans the Swift side for the same predicate set as
 * `/api/clips`.
 *
 * Run via scripts/check-frontend.sh (listed in the gates comment).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const webServer = readFileSync(join(root, 'Sources/ClipVault/HTTP/WebServer.swift'), 'utf8');
const database = readFileSync(join(root, 'Sources/ClipVault/Store/DatabaseManager.swift'), 'utf8');
const dayIndexSwift = readFileSync(join(root, 'Sources/ClipVault/Store/DayIndex.swift'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

/** Brace-matched `function name(...) { ... }` out of the inline app script. */
function fnSource(name) {
  const start = fnStart(html, name);
  const open = html.indexOf('{', paramListEnd(html, start));
  return html.slice(start, matchBrace(html, open) + 1);
}

function fnStart(src, name) {
  let start = src.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in web/index.html`);
  if (src.slice(start - 6, start) === 'async ') start -= 6;
  return start;
}

/** Index of the `)` closing the parameter list that opens at the first `(` after `start`. */
function paramListEnd(src, start) {
  const open = src.indexOf('(', start);
  let depth = 0;
  for (let i = open; i < src.length; i += 1) {
    if (src[i] === '(') depth += 1;
    else if (src[i] === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  throw new Error('unbalanced parameter list');
}

function matchBrace(src, open) {
  assert.ok(open >= 0, 'missing `{`');
  let depth = 0;
  for (let i = open; i < src.length; i += 1) {
    if (src[i] === '{') depth += 1;
    else if (src[i] === '}') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  throw new Error('unbalanced braces');
}

/** Body of a Swift `func name(...) { ... }` (same job, other language). */
function swiftFnSource(src, name) {
  const start = src.indexOf(`func ${name}(`);
  assert.ok(start >= 0, `${name} not found in Sources`);
  const open = src.indexOf('{', paramListEnd(src, start));
  return src.slice(start, matchBrace(src, open) + 1);
}

/** Brace-matched `const NAME = { ... };` / `[ ... ];` declaration. */
function declSource(name) {
  const start = html.indexOf(`const ${name} = `);
  assert.ok(start >= 0, `${name} not found in web/index.html`);
  const open = html.indexOf(html[start + `const ${name} = `.length], start);
  const closeCh = html[open] === '{' ? '}' : html[open] === '[' ? ']' : null;
  assert.ok(closeCh, `${name} is not an object/array literal`);
  let depth = 0;
  for (let i = open; i < html.length; i += 1) {
    if (html[i] === html[open]) depth += 1;
    else if (html[i] === closeCh) {
      depth -= 1;
      if (depth === 0) return html.slice(start, i + 1) + ';';
    }
  }
  throw new Error(`${name} has unbalanced braces`);
}

function constNumber(name) {
  const m = new RegExp(`const ${name} = (\\d+);`).exec(html);
  assert.ok(m, `missing const ${name} in web/index.html`);
  return Number(m[1]);
}

/** Bind real index.html code into one module scope with injected deps. */
function loadModule({ prologue = '', names, deps = {}, exports = '{}' }) {
  const keys = Object.keys(deps);
  const body = [
    keys.length ? `const { ${keys.join(', ')} } = deps;` : '',
    prologue,
    ...names.map(fnSource),
    `return (${exports});`,
  ].join('\n');
  return new Function('deps', body)(deps);
}

const BINS = 288;
const fiveMinuteBins = (spec = {}) => {
  const bins = new Array(BINS).fill(0);
  for (const [i, n] of Object.entries(spec)) bins[Number(i)] = n;
  return bins;
};

// ---------------------------------------------------------------------------
// 1. The client store: one request per filter set, never one per card.
// ---------------------------------------------------------------------------

function loadStore({ responses } = {}) {
  const calls = { urls: [], nm: [], heads: 0, served: 0 };
  const queue = responses ? [...responses] : null;
  const mod = loadModule({
    prologue: [
      'let currentView = "wall";',
      'let currentFilter = "all";',
      'let searchQuery = "";',
      'let wallParked = false;',
      'let dayStatsParkedDirty = false;',
      `const DAY_STATS_DEBOUNCE_MS = ${constNumber('DAY_STATS_DEBOUNCE_MS')};`,
      `const DAY_STATS_WAIT_MS = ${constNumber('DAY_STATS_WAIT_MS')};`,
      declSource('DayStats'),
    ].join('\n'),
    names: ['wallStatsSig', 'dayStatsFor', 'dayStatsApply', 'fetchDayIndex', 'withStatsTimeout', 'scheduleDayStats'],
    deps: {
      performance,
      API: '',
      window: { setTimeout: (fn, ms) => { calls.timers = calls.timers || []; calls.timers.push(ms); return calls.timers.length; } },
      nm: (name, meta) => calls.nm.push([name, meta]),
      refreshDayHeads: () => { calls.heads += 1; },
      liveGet: async (url) => {
        calls.urls.push(url);
        const body = queue ? queue[Math.min(calls.served, queue.length - 1)] : null;
        calls.served += 1;
        if (body && body.__status) return { ok: false, status: body.__status, json: async () => ({}) };
        return { ok: true, status: 200, json: async () => body };
      },
    },
    exports: `{
      wallStatsSig, dayStatsFor, dayStatsApply, fetchDayIndex, withStatsTimeout,
      setFilter(v) { currentFilter = v; },
      setView(v) { currentView = v; },
      setQuery(v) { searchQuery = v; },
      setParked(v) { wallParked = v; },
      parkedDirty() { return dayStatsParkedDirty; },
      canSchedule() { return typeof scheduleDayStats === 'function'; },
      schedule(reason) { return scheduleDayStats(reason); },
    }`,
  });
  return { mod, calls };
}

const DAY_PAYLOAD = {
  tz: 'Asia/Shanghai',
  binMinutes: 5,
  bins: BINS,
  count: 2,
  days: [
    {
      day: '2026-10-14', total: 106, timed: 106, night: 12, firstMin: 481, lastMin: 1320,
      maxGapMin: 240, gapFromMin: 600, gapToMin: 840, byType: { image: 100, text: 6 },
      bins: fiveMinuteBins({ 96: 3, 168: 2 }),
    },
    {
      day: '2026-10-13', total: 63, timed: 63, night: 0, firstMin: 500, lastMin: 1200,
      maxGapMin: null, gapFromMin: null, gapToMin: null, byType: { text: 63 },
      bins: fiveMinuteBins({ 100: 63 }),
    },
  ],
};

test('day-index gate is registered in check-frontend.sh', () => {
  assert.match(check, /day-index\.test\.mjs/);
  assert.match(check, /tests\/day_index_main\.swift/);
});

test('the header numbers come from the store payload, not from painted cards', async () => {
  const { mod, calls } = loadStore({ responses: [DAY_PAYLOAD] });
  assert.equal(mod.dayStatsFor('2026-10-14'), null, 'nothing cached before the first fetch');
  const ok = await mod.fetchDayIndex({ reason: 'reset' });
  assert.equal(ok, true);
  assert.equal(calls.urls.length, 1);
  assert.match(calls.urls[0], /^\/api\/clips\/days\?/);
  const day = mod.dayStatsFor('2026-10-14');
  assert.equal(day.total, 106);
  assert.equal(day.bins.length, BINS);
  assert.equal(day.night, 12);
  assert.equal(mod.dayStatsFor('2026-10-13').total, 63);
  assert.deepEqual(calls.nm.map(([n]) => n), ['wall_dayindex']);
  assert.equal(calls.nm[0][1].ok, true);
});

test('one filter set = one request; a new filter set never answers from the old days', async () => {
  const { mod, calls } = loadStore({ responses: [DAY_PAYLOAD, DAY_PAYLOAD] });
  await Promise.all([mod.fetchDayIndex(), mod.fetchDayIndex(), mod.fetchDayIndex()]);
  assert.equal(calls.urls.length, 1, 'concurrent callers share one in-flight request');
  assert.equal(mod.dayStatsFor('2026-10-14').total, 106);

  mod.setFilter('image');
  assert.equal(mod.dayStatsFor('2026-10-14'), null, 'a stale index must not answer for new filters');
  await mod.fetchDayIndex();
  assert.equal(calls.urls.length, 2);
  assert.match(calls.urls[1], /type=image/);
  assert.equal(mod.dayStatsFor('2026-10-14').total, 106);
});

test('the day-index query mirrors the wall query params (search is type-agnostic)', async () => {
  const { mod, calls } = loadStore({ responses: [DAY_PAYLOAD, DAY_PAYLOAD, DAY_PAYLOAD] });
  await mod.fetchDayIndex();
  assert.match(calls.urls[0], /exclude=note/, 'the wall never shows notes by default');

  mod.setFilter('html');
  await mod.fetchDayIndex();
  assert.match(calls.urls[1], /type=html/);

  mod.setView('trash');
  await mod.fetchDayIndex();
  assert.match(calls.urls[2], /view=trash/);
  assert.match(calls.urls[2], /type=html/);

  mod.setQuery('sqlite wal');
  mod.setFilter('all');
  await mod.fetchDayIndex();
  assert.match(calls.urls[3], /q=sqlite%20wal/, 'spaces must be percent-encoded, not `+`');
  assert.doesNotMatch(calls.urls[3], /type=/, 'clientFilter never hides FTS hits by type');
  assert.doesNotMatch(calls.urls[3], /exclude=/);
});

test('a failed index is reported and leaves the last good index in place', async () => {
  const { mod, calls } = loadStore({ responses: [DAY_PAYLOAD, { __status: 500 }] });
  await mod.fetchDayIndex();
  const ok = await mod.fetchDayIndex();
  assert.equal(ok, false);
  assert.equal(mod.dayStatsFor('2026-10-14').total, 106, 'the last good aggregate stays usable');
  const last = calls.nm.at(-1);
  assert.equal(last[0], 'wall_dayindex');
  assert.equal(last[1].ok, false);
  assert.equal(last[1].payload.reason, 'reset');
});

test('refreshes are coalesced, and a parked wall fetches nothing', async () => {
  const { mod, calls } = loadStore({ responses: [DAY_PAYLOAD, DAY_PAYLOAD] });
  // The debounce timer is the only scheduler; a live burst must not fan out.
  assert.equal(mod.canSchedule(), true);
  assert.match(fnSource('scheduleDayStats'), /if \(DayStats\.timer\) return;/);
  assert.match(fnSource('scheduleDayStats'), /DAY_STATS_DEBOUNCE_MS/);
  mod.setParked(true);
  mod.schedule('live');
  assert.equal(calls.urls.length, 0, 'a parked wall does not spend a request');
  assert.equal(mod.parkedDirty(), true);
  // …and the wake path replays it (wiring asserted below).
  assert.match(fnSource('wakeWall'), /if \(dayStatsParkedDirty\) \{[\s\S]*scheduleDayStats\('wake'\)/);
});

test('the wall awaits the index for page 1 and patches if it lands late', () => {
  const body = fnSource('fetchPage');
  assert.match(body, /const statsP = reset \? fetchDayIndex\(\{ reason: 'reset' \}\) : null;/);
  assert.match(body, /const statsLanded = statsP \? await withStatsTimeout\(statsP\) : true;/);
  assert.match(body, /if \(!statsLanded\) void statsP\.then\(\(ok\) => \{ if \(ok\) refreshDayHeads\(\); \}\);/);
  // A slow index must not hold the wall hostage, but it must not be dropped either.
  assert.match(fnSource('withStatsTimeout'), /Promise\.race\(\[/);
  assert.match(fnSource('withStatsTimeout'), /DAY_STATS_WAIT_MS/);
  // Every mutation that can move a day's numbers invalidates the index.
  assert.match(fnSource('applyFreshItems'), /scheduleDayStats\('live'\)/);
  assert.match(fnSource('applyRemoteClipRemoval'), /scheduleDayStats\('remove'\)/);
  assert.match(fnSource('applyLocalPin'), /scheduleDayStats\('pin'\)/);
});

// ---------------------------------------------------------------------------
// 2. The rendered header: store aggregate, or an honest lower bound.
// ---------------------------------------------------------------------------

function loadHead() {
  return loadModule({
    prologue: [
      declSource('DayGroups'),
      declSource('DayRhythm'),
      'let rhythmTrack = null;',
      'const rhythmScrubSchedule = () => {};',
      'const wallTodayKey = () => "2026-10-14";',
      'const wallNowMinute = () => 600;',
    ].join('\n'),
    names: ['dayBucketMeta', 'dayRhythmBand', 'dayRhythmMarkup', 'dayHeadMarkup'],
    deps: {
      esc: (s) => String(s ?? ''),
      escAttr: (s) => String(s ?? ''),
      typeMeta: (bucket) => ({ label: '类型' + bucket, icon: 'circle', cls: 'type-' + bucket }),
    },
    exports: '{ dayHeadMarkup, dayRhythmMarkup }',
  });
}

test('a day head with the store aggregate prints the day total and its type pills', () => {
  const mod = loadHead();
  const group = {
    day: '2026-10-14',
    items: [{ type: 'image' }, { type: 'image' }],   // two painted cards of 106 captures
  };
  const out = mod.dayHeadMarkup(group, DAY_PAYLOAD.days[0]);
  assert.match(out, /共 106 条/);
  assert.doesNotMatch(out, /共 2 条/, 'the painted slice must never define the total');
  assert.doesNotMatch(out, /&#8805;/, 'a full aggregate is not a lower bound');
  assert.doesNotMatch(out, /is-partial/);
  // Pills mirror the store's raw types through the shared rich-collapse rule.
  assert.match(out, /类型image 100/);
  assert.match(out, /类型text 6/);
  assert.doesNotMatch(out, /类型rich/, 'no html/rtf in this payload');
  // The strip is the store's histogram: 288 marks, night marks included.
  assert.equal((out.match(/class="rhythm-bar/g) || []).length, BINS);
  assert.match(out, /data-rhythm-total="106"/);
});

test('html + rtf from the store collapse into one 富文本 pill (same rule as a slice)', () => {
  const mod = loadHead();
  const out = mod.dayHeadMarkup(
    { day: '2026-10-14', items: [] },
    { day: '2026-10-14', total: 5, timed: 5, night: 0, firstMin: 600, lastMin: 620, byType: { html: 3, rtf: 2 }, bins: fiveMinuteBins({ 120: 5 }) },
  );
  assert.match(out, /富文本 5/);
  assert.doesNotMatch(out, /类型html/);
});

test('without the index the head says `≥`, drops the pills and dims the strip', () => {
  const mod = loadHead();
  const out = mod.dayHeadMarkup({ day: '2026-10-14', items: [{ type: 'image' }, { type: 'image' }] });
  assert.match(out, /&#8805; 共 2 条/);
  assert.match(out, /is-partial/);
  assert.match(out, /title="当日统计仍在同步[^"]*"/);
  assert.match(out, /day-rhythm is-partial/);
  // No type pills from a painted slice, but the row keeps a badge so the store
  // payload (late-index patch) does not change the head's height.
  assert.doesNotMatch(out, /class="badge type-/, 'partial type pills would be a guess');
  assert.match(out, /class="badge is-pending">统计同步中</);
  assert.match(out, /当日统计仍在同步/, 'the paragraph above still explains it');
});

test('a day with no aggregate and no loaded cards stays renderable', () => {
  const mod = loadHead();
  const out = mod.dayHeadMarkup({ day: '2026-10-01', items: [] });
  assert.match(out, /&#8805; 共 0 条/);
  assert.match(out, /无时间/);
  assert.equal((out.match(/class="rhythm-bar/g) || []).length, 0);
});

// ---------------------------------------------------------------------------
// 3. The store side: same predicate set as /api/clips, same clock as the cards.
// ---------------------------------------------------------------------------

test('GET /api/clips/days is routed before the /api/clips prefix handlers', () => {
  assert.match(webServer, /pathOnly == "\/api\/clips\/days"[\s\S]{0,80}sendDayIndexJSON\(path: path, connection: connection\)/);
  assert.match(webServer, /private func sendDayIndexJSON\(path: String, connection: HTTPByteSink\)/);
  // Day keys must come from the same zone that renders each card's `timeLocal`.
  assert.match(webServer, /DayIndexBuilder\.build\(rows: rows, zone: ClipTimeFormat\.displayTimeZone\)/);
  assert.match(database, /func fetchDayIndexRows\(/);
});

test('the day aggregate mirrors the wall predicate set exactly', () => {
  const body = swiftFnSource(database, 'fetchDayIndexRows');
  assert.match(body, /trashOnly: Bool = false/);
  assert.match(body, /typeFilter: String\? = nil/);
  assert.match(body, /excludeType: String\? = nil/);
  // Same list rule as runList / wallRestItems: no trash, and pinned rows are not
  // in the day sections (they live in the pin rail).
  assert.match(database, /sql \+= "deleted_at IS NULL AND pinned_at IS NULL"/);
  assert.match(database, /sql \+= "deleted_at IS NOT NULL"/);
  assert.match(database, /Self\.typePredicateSQL\(alias: "c", typeFilter: typeFilter, excludeType: excludeType\)/);
  // Search mirrors the page path: FTS first, LIKE only when FTS came back empty.
  assert.match(body, /if rows\.isEmpty \{/);
  assert.match(body, /self\.ftsTokenizer == "trigram"/);
});

test('the aggregate ships raw types + 288 marks; the client owns presentation', () => {
  assert.match(dayIndexSwift, /static let binMinutes = 5/);
  assert.match(dayIndexSwift, /static let binCount = \(24 \* 60\) \/ binMinutes/);
  assert.match(dayIndexSwift, /byType\[row\.type\.lowercased\(\), default: 0\] \+= 1/, 'types stay raw');
  // Exact facts, not bin-rounded ones: the strip only illustrates them.
  assert.match(dayIndexSwift, /entry\.night = sorted\.reduce/);
  assert.match(dayIndexSwift, /entry\.maxGapMin = best/);
  // Day keys are computed in the display zone, DST-safe, without a formatter per row.
  assert.match(dayIndexSwift, /zone\.secondsFromGMT\(for: Date\(timeIntervalSince1970: timestamp\)\)/);
});

test('the day index has a budgeted metric of its own', () => {
  assert.match(html, /nm\('wall_dayindex'/);
  assert.match(html, /wall_dayindex: \{ label: '日统计', unit: 'ms', budget: 120 \}/);
  assert.match(fnSource('fetchDayIndex'), /nm\('wall_dayindex'[\s\S]{0,200}ok: false/);
});

test('one aggregate request can never be replaced by per-card counting', () => {
  // The head must not call the loaded-slice stats on the aggregate path.
  assert.match(fnSource('dayHeadMarkup'), /const partial = !serverStats;/);
  assert.match(fnSource('dayHeadMarkup'), /partial \? DayGroups\.stats\(group\.items\) : null/);
  // Reconcile/update paths hand the store aggregate to the head.
  assert.match(fnSource('reconcileDaySections'), /updateDayHead\(sec, g, dayStatsFor\(g\.day\)\)/);
  assert.match(fnSource('refreshDayHeadsFor'), /updateDayHead\(sec, \{ day: d, items: byDay\.get\(d\) \|\| \[\] \}, dayStatsFor\(d\)\)/);
  assert.match(fnSource('refreshDayHeads'), /updateDayHead\(sec, \{ day, items: \[\] \}, dayStatsFor\(day\)\)/);
});
