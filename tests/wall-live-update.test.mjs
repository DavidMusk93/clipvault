/**
 * Live-update gate: an SSE / sync `update` must reach the model **in full** and on the
 * capture clock.
 *
 * Two product-loss modes this file executes, not just greps:
 *   1. A pull burst folded into one head merge. `wall_merge {"kind":"burst","n":3000}`
 *      was recorded on 2026-10-09 while `mergeHead` only ever pulls `PAGE_SIZE` (30)
 *      cards — ~2970 captured clips were in SQLite but absent from the wall until a
 *      reload. Draining by id must apply every id.
 *   2. A `kind=touch` re-copy bumps `clipboard_items.timestamp` (WallClockPolicy), so
 *      the row moves in the capture timeline. Reporting `'have'` on the stale position
 *      (and advancing `lastHeadSig`) left the card in its old day until a reload.
 *
 * Run via scripts/check-frontend.sh (listed in the gates comment).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

// jsdom is a dev-only dependency (`npm ci`). Load it once, defensively: the
// capture-clock assertions only read web/index.html and must keep running in a
// bare environment, and the day-scoped DOM test must degrade to a *reported*
// skip instead of an ERR_MODULE_NOT_FOUND that kills the whole file.
let JSDOM = null;
let skipJsdom = false;
try {
  ({ JSDOM } = await import('jsdom'));
} catch {
  skipJsdom = 'jsdom not installed — run `npm ci`';
}

/** Brace-matched `function name(...) { ... }` out of the inline app script (keeps `async`). */
function fnSource(name) {
  let start = html.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in web/index.html`);
  if (html.slice(start - 6, start) === 'async ') start -= 6;
  const open = html.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth += 1;
    else if (html[i] === '}') {
      depth -= 1;
      if (depth === 0) return html.slice(start, i + 1);
    }
  }
  throw new Error(`${name} has unbalanced braces`);
}

/** Read a numeric constant straight from index.html so a value change fails the gate. */
function constNumber(name) {
  const m = new RegExp(`const ${name} = (\\d+);`).exec(html);
  assert.ok(m, `missing const ${name} in web/index.html`);
  return Number(m[1]);
}

/**
 * Bind real index.html functions into one module scope with injected deps.
 * `deps` are destructured before `prologue`, `names` are the extracted functions,
 * `exports` is the object expression the module returns (state accessors included).
 */
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

// ---------------------------------------------------------------------------
// 1. Burst drain: every id must be applied, bounded per pass, never a head merge.
// ---------------------------------------------------------------------------

function loadFlush() {
  const calls = { one: [], chunks: [], applied: [], resync: 0, timers: [] };
  const mod = loadModule({
    prologue: [
      'let pendingUpdateIds = new Set();',
      'let updateFlushTimer = 0;',
      `const UPDATE_IDS_MAX = ${constNumber('UPDATE_IDS_MAX')};`,
      `const UPDATE_CHUNK = ${constNumber('UPDATE_CHUNK')};`,
      `const UPDATE_FLUSH_MS = ${constNumber('UPDATE_FLUSH_MS')};`,
    ].join('\n'),
    names: ['wallFlushPlan', 'flushPendingUpdates', 'ingestClipIds', 'flushParkedUpdates'],
    deps: {
      window: { setTimeout: (fn, ms) => { calls.timers.push([fn, ms]); return 1; } },
      nm: () => {},
      ingestClipById: (id) => { calls.one.push(id); },
      scheduleResync: () => { calls.resync += 1; },
      fetchClipsByIds: async (ids) => { calls.chunks.push([...ids]); return ids.map((id) => ({ id })); },
      applyFreshItems: (items) => { calls.applied.push(items.length); return items.length; },
    },
    exports: `{
      wallFlushPlan, flushPendingUpdates, ingestClipIds, flushParkedUpdates,
      setIds(list) { pendingUpdateIds = new Set(list); },
      queued() { return [...pendingUpdateIds]; },
    }`,
  });
  return { mod, calls };
}

/** Let the module's voided async ingest settle (chunk fetches are awaited in order). */
function settle() {
  return new Promise((resolve) => setImmediate(resolve));
}

test('wall-live-update gate is registered in check-frontend.sh', () => {
  assert.match(check, /wall-live-update\.test\.mjs/);
});

test('a 3000-id pull burst is drained in full, by id, with no id dropped', async () => {
  const { mod, calls } = loadFlush();
  const ids = Array.from({ length: 3000 }, (_, i) => `ID-${i}`);
  const bound = constNumber('UPDATE_IDS_MAX');
  mod.setIds(ids);

  // Pass 1: one bounded pass goes out (chunked), the tail stays queued for the next tick.
  mod.flushPendingUpdates();
  await settle();
  assert.equal(mod.queued().length, 3000 - bound, 'the tail stays queued — it is not dropped');
  assert.equal(calls.timers.length, 1, 'the remainder drains on the next tick');
  assert.equal(calls.timers[0][1], constNumber('UPDATE_FLUSH_MS'));
  assert.equal(calls.resync, 0, 'a burst must never degrade into a 30-card head merge');
  assert.deepEqual(calls.one, [], 'a burst never becomes one fetch per item');
  assert.equal(calls.chunks.length, Math.ceil(bound / constNumber('UPDATE_CHUNK')), 'chunked fetch');
  assert.deepEqual(calls.chunks.flat(), ids.slice(0, bound), 'first pass in order, nothing dropped');
  assert.deepEqual(calls.applied, [bound], 'one repaint for the whole pass');

  // Pass 2: the drain completes.
  mod.flushPendingUpdates();
  await settle();
  assert.equal(mod.queued().length, 0, 'queue drained');
  assert.deepEqual(calls.chunks.flat(), ids, 'every id reached the ingest path exactly once');
});

test('one capture keeps the one-card path; parked flush shares one ingest truth', async () => {
  const { mod, calls } = loadFlush();
  assert.equal(mod.wallFlushPlan([], constNumber('UPDATE_IDS_MAX')), 'none');
  assert.equal(mod.wallFlushPlan(['a'], constNumber('UPDATE_IDS_MAX')), 'ids');

  mod.setIds(['single-1']);
  mod.flushPendingUpdates();
  assert.deepEqual(calls.one, ['single-1']);
  assert.deepEqual(calls.chunks, []);

  mod.setIds(['a', 'b', 'c']);
  await mod.flushParkedUpdates();
  assert.deepEqual(calls.chunks, [['a', 'b', 'c']], 'a wake batch is one bounded call');
  assert.equal(calls.applied.length, 1, 'and one repaint');
});

test('wiring: single-id path and parked flush call the shared helpers', () => {
  assert.match(
    fnSource('flushPendingUpdates'),
    /if \(pass\.length === 1\) \{ void ingestClipById\(pass\[0\]\); return; \}/,
  );
  assert.match(fnSource('flushParkedUpdates'), /await ingestClipIds\(ids\)/);
});

// ---------------------------------------------------------------------------
// 2. Capture clock: a re-copy moves the row, and the wall must follow it.
// ---------------------------------------------------------------------------

function loadApply() {
  const moves = [];
  const rebuilds = [];
  const prepends = [];
  const dayStats = [];
  const mod = loadModule({
    prologue: [
      'let clips = [];',
      'let colHeights = null;',
      "let lastHeadSig = '';",
      `const PAGE_SIZE = ${constNumber('PAGE_SIZE')};`,
    ].join('\n'),
    names: ['sortClipsForFeed', 'dedupeClipsById', 'clipHeadSig', 'applyFreshItems'],
    deps: {
      itemIsPinned: (i) => !!(i && i.pinnedAt),
      rebuildFromData: (o) => { rebuilds.push(o || null); },
      prependCardsIncremental: (items) => { prepends.push([...items]); },
      clientFilter: (list) => list,
      moveTouchedCards: (items) => { moves.push([...items]); return items.length; },
      // Day headers are refetched from the store, never recounted from the model.
      scheduleDayStats: (reason) => { dayStats.push(reason); },
    },
    exports: `{
      sortClipsForFeed, dedupeClipsById, clipHeadSig, applyFreshItems,
      setClips(list) { clips = list; },
      getClips() { return clips; },
    }`,
  });
  return { mod, moves, rebuilds, prepends, dayStats };
}

test('a re-copy (newer capture timestamp) moves the row instead of being ignored', () => {
  const { mod, moves, dayStats } = loadApply();
  mod.setClips([
    { id: 'A', timestamp: 100, type: 'text', day: 'D-old' },
    { id: 'B', timestamp: 90, type: 'text', day: 'D-old' },
  ]);
  const applied = mod.applyFreshItems([{ id: 'A', timestamp: 200, type: 'text', day: 'D-new' }]);
  assert.equal(applied, 1, 'the move counts as applied work');
  assert.deepEqual(mod.getClips().map((c) => c.id), ['A', 'B'], 'A is now the newest row');
  assert.equal(mod.getClips()[0].timestamp, 200, 'the model carries the capture clock');
  assert.deepEqual(moves.map((m) => m.map((i) => i.id)), [['A']], 'the card follows in the feed');
  assert.deepEqual(dayStats, ['live'], 'the day header is re-aggregated from the store, not from the moved card');
});

test('an unchanged or older timestamp is a no-op (no churn, no repaint)', () => {
  const { mod, moves, rebuilds, prepends } = loadApply();
  mod.setClips([{ id: 'A', timestamp: 200, type: 'text', day: 'D0' }]);
  assert.equal(mod.applyFreshItems([{ id: 'A', timestamp: 200, type: 'text', day: 'D0' }]), 0);
  assert.equal(mod.applyFreshItems([{ id: 'A', timestamp: 150, type: 'text', day: 'D0' }]), 0);
  assert.deepEqual(moves, []);
  assert.deepEqual(rebuilds, []);
  assert.deepEqual(prepends, []);
});

test('the head signature carries the capture clock', () => {
  const { mod } = loadApply();
  const before = mod.clipHeadSig([{ id: 'A', timestamp: 100 }]);
  const after = mod.clipHeadSig([{ id: 'A', timestamp: 200 }]);
  assert.notEqual(before, after, 'a timestamp-only change must be visible to mergeHead');
  assert.equal(mod.clipHeadSig([{ id: 'A', timestamp: 100 }]), before, 'stable when unchanged');
});

// The metric that was missing on 2026-10-14: nothing measured "the model still disagrees
// with the server", so a wall that quietly stopped applying updates never turned red.
test('head drift is measured after the merge, so a real failure is visible', () => {
  const mod = loadModule({
    names: ['headDriftBreakdown', 'headDriftCount'],
    deps: {},
    exports: '{ headDriftBreakdown, headDriftCount }',
  });
  const server = [
    { id: 'A', timestamp: 200, pinnedAt: 5 },
    { id: 'B', timestamp: 100, pinnedAt: null },
  ];
  assert.equal(mod.headDriftCount(server, [
    { id: 'A', timestamp: 200, pinnedAt: 5 },
    { id: 'B', timestamp: 100, pinnedAt: null },
  ]), 0);
  // A kind=touch re-copy the model never followed.
  assert.equal(mod.headDriftCount(server, [{ id: 'A', timestamp: 100 }, { id: 'B', timestamp: 100 }]), 1);
  // A burst id that never landed.
  assert.equal(mod.headDriftCount(server, [{ id: 'B', timestamp: 100 }]), 1);
  // A pin the model missed.
  assert.equal(mod.headDriftCount(server, [{ id: 'A', timestamp: 200, pinnedAt: 9 }, { id: 'B', timestamp: 100 }]), 1);
  // mergeHead must report residual drift (budget 0) instead of applying silently.
  assert.match(fnSource('mergeHead'), /noteHeadDrift\(items, 'head'\)/);
  assert.match(fnSource('noteHeadDrift'), /nm\('wall_head_drift'/);
  assert.match(fnSource('noteHeadDrift'), /over: drift > 0/);
});

// ---------------------------------------------------------------------------
// 3. A move the tab never got an `update` for must still land on the resync.
//    Reproduced live 2026-10-15: freeze the page, re-copy a clip (kind=touch
//    bumps `timestamp`), come back → `visibilitychange` → `mergeHead` reported
//    `noop` and the card kept its old position forever (wall_head_drift 2-4).
// ---------------------------------------------------------------------------

function loadMergeHead(headItems, fullItems = {}) {
  const calls = { urls: [], merges: [], drift: [], moves: [] };
  const mod = loadModule({
    prologue: [
      'let clips = [];',
      "let lastHeadSig = '';",
      "const searchQuery = '';",
      "const currentView = 'all';",
      "const currentFilter = 'all';",
      `const PAGE_SIZE = ${constNumber('PAGE_SIZE')};`,
      "const API = '';",
    ].join('\n'),
    names: [
      'applyWallQueryParams', 'clipHeadSig', 'headDriftBreakdown', 'headDriftCount',
      'noteHeadDrift', 'pinFieldsFrom', 'sortClipsForFeed', 'dedupeClipsById',
      'applyFreshItems', 'fetchClipById', 'mergeHead',
    ],
    deps: {
      nm: (name, payload) => {
        if (name === 'wall_merge') calls.merges.push(payload);
        if (name === 'wall_head_drift') calls.drift.push(payload);
      },
      liveGet: async (url) => {
        calls.urls.push(url);
        const items = /ids=|id=/.test(url)
          ? Object.values(fullItems)
          : headItems;
        return {
          ok: true,
          headers: { get: () => null },
          json: async () => ({ items }),
        };
      },
      itemIsPinned: (i) => !!(i && i.pinnedAt),
      patchCardLinkState: () => {},
      rebuildFromData: () => {},
      replaceCardInPlace: () => {},
      prependCardsIncremental: () => {},
      clientFilter: (list) => list,
      moveTouchedCards: (items) => { calls.moves.push(items.map((i) => i.id)); return items.length; },
      scheduleDayStats: () => {},
    },
    exports: `{
      mergeHead,
      setClips(list) { clips = list; },
      getClips() { return clips; },
      setSig(s) { lastHeadSig = s; },
    }`,
  });
  return { mod, calls };
}

const headRow = (id, timestamp, extra = {}) => ({
  id, timestamp, type: 'text', pinned: false, pinnedAt: null,
  archived: false, inTrash: false, linkCount: 0, ...extra,
});

test('mergeHead follows a kind=touch move the SSE update never delivered', async () => {
  const { mod, calls } = loadMergeHead([headRow('A', 200), headRow('B', 90)]);
  mod.setClips([
    { id: 'A', timestamp: 100, type: 'text' },
    { id: 'B', timestamp: 90, type: 'text' },
  ]);

  await mod.mergeHead();

  assert.deepEqual(mod.getClips().map((c) => c.id), ['A', 'B'], 'A moved to the top of the capture order');
  assert.equal(mod.getClips()[0].timestamp, 200, 'the model carries the bumped capture clock');
  assert.deepEqual(calls.moves, [['A']], 'the card follows, day-scoped, not a full rebuild');
  assert.deepEqual(calls.urls.filter((u) => /ids=|id=/.test(u)), [],
    'the head payload already carries the clock — a move needs no extra fetch');
  const end = calls.merges.find((m) => m.payload && m.payload.kind === 'head' && m.payload.phase === 'end');
  assert.ok(end, 'the merge reports its end state');
  assert.equal(end.payload.reason, 'move', 'the metric names the move instead of reporting noop');
  assert.equal(end.payload.moved, 1);
  const drift = calls.drift.at(-1).payload;
  assert.equal(drift.miss, 0, 'the post-merge drift check is honest: the model now agrees');
  assert.equal(drift.stale_ts, 0);
});

test('mergeHead still inserts unknown ids and never rewinds the capture clock', async () => {
  const { mod, calls } = loadMergeHead([
    headRow('C', 300),
    headRow('A', 100),
    headRow('B', 90),
  ], { C: { id: 'C', timestamp: 300, type: 'text' } });
  mod.setClips([
    { id: 'A', timestamp: 100, type: 'text' },
    { id: 'B', timestamp: 90, type: 'text' },
  ]);

  await mod.mergeHead();

  assert.deepEqual(mod.getClips().map((c) => c.id), ['C', 'A', 'B'], 'the new row is inserted, A stays put');
  assert.deepEqual(calls.moves, [], 'only a *newer* clock moves a card');
  const end = calls.merges.find((m) => m.payload && m.payload.kind === 'head' && m.payload.phase === 'end');
  assert.equal(end.payload.reason, 'insert');
  assert.equal(calls.drift.at(-1).payload.miss, 0);
  assert.equal(calls.drift.at(-1).payload.stale_ts, 0);

  // A server clock *older* than the model is a disagreement we deliberately refuse to
  // follow — rewriting the capture order backwards is the 拨钟 failure, not a fix.
  const back = loadMergeHead([headRow('A', 50)]);
  back.mod.setClips([{ id: 'A', timestamp: 100, type: 'text' }]);
  await back.mod.mergeHead();
  assert.equal(back.mod.getClips()[0].timestamp, 100, 'the model keeps the newer capture clock');
  assert.deepEqual(back.calls.moves, []);
  const backDrift = back.calls.drift.at(-1).payload;
  assert.equal(backDrift.stale_ts, 1, 'and the disagreement is still reported, not hidden');
  assert.equal(backDrift.id0, 'A', 'the metric names the row so the failure can be looked up');
});

test('the drift metric names what disagrees, not just how many', () => {
  const mod = loadModule({
    names: ['headDriftBreakdown', 'headDriftCount', 'noteHeadDrift'],
    deps: { nm: () => {}, clips: [] },
    exports: '{ headDriftBreakdown, headDriftCount }',
  });
  const b = mod.headDriftBreakdown([
    { id: 'gone', timestamp: 1 },
    { id: 'moved', timestamp: 200 },
    { id: 'pinned', timestamp: 5, pinnedAt: 9 },
  ], [{ id: 'moved', timestamp: 100 }, { id: 'pinned', timestamp: 5, pinnedAt: 1 }]);
  assert.deepEqual(b.missing, ['gone']);
  assert.deepEqual(b.staleTs, ['moved']);
  assert.deepEqual(b.stalePin, ['pinned']);
  assert.equal(mod.headDriftCount([], []), 0);
});

test('a moved card leaves its old day, updates both headers, repacks only those days', { skip: skipJsdom }, async () => {
  const dom = new JSDOM(
    '<div id="grid">'
    + '<section class="day-group" data-day="2026/10/01">'
    + '<header class="day-head"></header>'
    + '<div class="masonry day-masonry"></div>'
    + '</section>'
    + '</div>',
  );
  const { document } = dom.window;
  const feed = document.getElementById('grid');
  const oldHost = feed.querySelector('.day-masonry');
  const card = document.createElement('div');
  card.className = 'm3-card';
  card.dataset.id = 'A';
  oldHost.appendChild(card);

  const refreshed = [];
  const packed = [];
  const mod = loadModule({
    prologue: [
      'let colHeights = 12;',
      `let clips = [{ id: 'A', type: 'text', day: '2026/10/14' }];`,
    ].join('\n'),
    names: ['moveTouchedCards'],
    deps: {
      clientFilter: (list) => list,
      rebuildFromData: () => { throw new Error('a day-scoped move must not rebuild the whole wall'); },
      wallFeedEl: () => feed,
      DayGroups: {
        keyForItem: () => '2026/10/14',
        group: () => [{ day: '2026/10/14' }],
      },
      renderDayRail: () => false,
      wallRestItems: () => [],
      captureWallAnchor: () => null,
      cardCache: new Map([['A', card]]),
      ensureDaySection: (f, day) => {
        let sec = null;
        for (const el of f.children) {
          if (el.classList && el.classList.contains('day-group') && el.dataset.day === day) sec = el;
        }
        if (!sec) {
          sec = document.createElement('section');
          sec.className = 'day-group';
          sec.dataset.day = day;
          sec.innerHTML = '<header class="day-head"></header><div class="masonry day-masonry"></div>';
          f.appendChild(sec);
        }
        return sec;
      },
      dayHostOf: (sec) => (sec ? sec.querySelector('.day-masonry') : null),
      daySectionEl: (f, day) => {
        for (const el of f.children) {
          if (el.classList && el.classList.contains('day-group') && el.dataset.day === day) return el;
        }
        return null;
      },
      refreshDayHeadsFor: (days) => { refreshed.push([...days].sort()); },
      layoutMasonry: (host) => { packed.push(host.closest('.day-group').dataset.day); },
      restoreWallAnchor: () => {},
      observeDaySections: () => {},
      window: { scrollY: 0 },
      document: dom.window.document,
    },
    exports: '{ moveTouchedCards }',
  });

  const moved = mod.moveTouchedCards([{ id: 'A', type: 'text', day: '2026/10/14' }]);
  assert.equal(moved, 1);
  let newSec = null;
  for (const el of feed.children) {
    if (el.dataset.day === '2026/10/14') newSec = el;
  }
  assert.ok(newSec, 'the moved card opens its own capture day');
  assert.equal(newSec.querySelector('.m3-card').dataset.id, 'A', 'same card identity moved');
  assert.equal(oldHost.querySelector('.m3-card'), null, 'the card left its old day');
  assert.deepEqual(refreshed, [['2026/10/01', '2026/10/14']], 'both day headers keep honest counts');
  assert.deepEqual(packed.slice().sort(), ['2026/10/01', '2026/10/14'], 'only the affected days repack');
});
