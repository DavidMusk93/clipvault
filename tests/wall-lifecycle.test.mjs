/**
 * Wall lifecycle gate: an unattended page must stop painting, and a pull burst
 * must not become one fetch + one repaint per item on every tab.
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

function htmlFn(name) {
  const re = new RegExp(`function ${name}\\b`);
  const m = re.exec(html);
  assert.ok(m, `missing function ${name}`);
  // Skip the parameter list (parens may contain default-object braces).
  const paren = html.indexOf('(', m.index);
  assert.ok(paren > 0, `missing params for ${name}`);
  let pdepth = 0;
  let afterParams = paren;
  for (let i = paren; i < html.length; i++) {
    if (html[i] === '(') pdepth++;
    else if (html[i] === ')') {
      pdepth--;
      if (pdepth === 0) { afterParams = i; break; }
    }
  }
  const start = html.indexOf('{', afterParams);
  assert.ok(start > 0, `missing body for ${name}`);
  let depth = 0;
  for (let i = start; i < html.length; i++) {
    const ch = html[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return html.slice(m.index, i + 1);
    }
  }
  return html.slice(m.index, start + 4000);
}

test('wall lifecycle gate is registered in check-frontend.sh', () => {
  assert.match(check, /wall-lifecycle\.test\.mjs/);
});

test('parked state stops every paint entry point', () => {
  for (const fn of [
    'rebuildFromData',
    'layoutMasonry',
    'prependCardsIncremental',
    'appendCardsIncremental',
    'ensureCard',
    'replaceCardInPlace',
    'removeCardFromMasonry',
    'scheduleRebalance',
  ]) {
    const body = htmlFn(fn);
    assert.match(body, /wallParked/, `${fn} must bail while parked`);
    assert.match(body, /parkedPaintDirty = true/, `${fn} must mark a catch-up paint`);
  }
  // Late-height drift must not re-pack while parked.
  assert.match(html, /cardResizeObs = new ResizeObserver\(\(entries\) => \{\n\s+if \(wallParked\) \{ parkedPaintDirty = true; return; \}/);
});

test('wake repaints exactly once from the complete model', () => {
  const wake = htmlFn('wakeWall');
  assert.match(wake, /wallParked = false/);
  assert.match(wake, /parkedPaintDirty/);
  assert.match(wake, /rebuildFromData\(\{ preserveScroll: true \}\)/);
  // Buffered ids flush before the catch-up paint.
  assert.match(wake, /flushParkedUpdates\(\)/);
  assert.match(wake, /parkedHeadStale/);
  // No second repaint path in wake.
  assert.equal((wake.match(/rebuildFromData\(/g) || []).length, 1);
  assert.match(html, /nm\('wall_lifecycle'/);
  assert.match(html, /phase: 'park'/);
  assert.match(html, /phase: 'wake'/);
});

test('park decision is hidden OR no user input for the idle lease', () => {
  const body = htmlFn('wallShouldPark');
  // Mirror of the pure helper embedded in web/index.html.
  const wallShouldPark = (now, hidden, lastInputAt, idleMs) => {
    if (hidden) return true;
    return (now - lastInputAt) >= idleMs;
  };
  assert.match(body, /if \(hidden\) return true/);
  assert.match(body, />= idleMs/);
  assert.equal(wallShouldPark(1000, true, 999, 90000), true);
  assert.equal(wallShouldPark(1000, false, 1000, 90000), false);
  assert.equal(wallShouldPark(1000 + 89999, false, 1000, 90000), false);
  assert.equal(wallShouldPark(1000 + 90000, false, 1000, 90000), true);
});

test('real user input wakes the wall; visibility hidden parks it', () => {
  const input = htmlFn('noteWallInput');
  assert.match(input, /wallLastInputAt = Date\.now\(\)/);
  assert.match(input, /wakeWall\('input'\)/);
  for (const ev of ['pointerdown', 'pointermove', 'keydown', 'wheel', 'touchstart']) {
    assert.match(html, new RegExp(`'${ev}'`), `missing ${ev} wake listener`);
  }
  assert.doesNotMatch(html, /window\.addEventListener\(evName, noteWallInput, \{ passive: true, capture: true \}\)[^\n]*scroll/, 'scroll must not wake (programmatic anchor)')
  assert.doesNotMatch(html, /'scroll'\]/, 'scroll must not be a wake event');
  assert.match(html, /window\.addEventListener\(evName, noteWallInput/);
  const vis = htmlFn('onFeedVisible');
  assert.match(vis, /parkWall\('hidden'\)/);
  assert.match(vis, /wakeWall\('visible'\)/);
  // Solo hidden tab still elects/keeps the EventSource (sse-control.test.mjs owns the full rule).
  assert.match(vis, /considerElect\(\)/);
  assert.doesNotMatch(vis, /teardownSSE\(\)/);
});

test('update burst coalesces to bounded by-id batches, never to a 30-card head merge', () => {
  const plan = htmlFn('wallFlushPlan');
  const wallFlushPlan = (ids, max) => {
    if (!ids || !ids.length) return 'none';
    return ids.length > max ? 'drain' : 'ids';
  };
  assert.match(plan, /return 'none'/);
  assert.match(plan, /return ids\.length > max \? 'drain' : 'ids'/);
  assert.equal(wallFlushPlan([], 2048), 'none');
  assert.equal(wallFlushPlan(['a'], 2048), 'ids');
  assert.equal(wallFlushPlan(new Array(2049).fill('a'), 2048), 'drain');

  const flush = htmlFn('flushPendingUpdates');
  // A burst is drained in full: the tail goes back on the queue and the next tick
  // applies it. `scheduleResync()` here would mean a head merge, which only ever
  // pulls PAGE_SIZE cards and silently drops every id past the first page.
  assert.match(flush, /UPDATE_IDS_MAX/);
  assert.match(flush, /for \(const id of rest\) pendingUpdateIds\.add\(id\)/);
  assert.match(flush, /ingestClipIds\(pass\)/);
  assert.doesNotMatch(flush, /scheduleResync\(\)/);

  const batch = htmlFn('ingestClipIds');
  assert.match(batch, /fetchClipsByIds\(list\.slice/);
  assert.match(batch, /applyFreshItems\(got\)/);

  const sched = htmlFn('scheduleUpdateIngest');
  assert.match(sched, /pendingUpdateIds\.add\(sid\)/);
  // Parked: buffer only, no timer, no fetch, bounded.
  assert.match(sched, /if \(wallParked\) \{/);
  assert.match(sched, /pendingUpdateIds\.size >= UPDATE_PARKED_MAX/);
  assert.match(sched, /parkedHeadStale = true/);
  assert.match(sched, /setTimeout\(flushPendingUpdates, UPDATE_FLUSH_MS\)/);
  assert.doesNotMatch(sched, /wallParked \?/, 'parked must not schedule any flush timer');

  const parkedFlush = htmlFn('flushParkedUpdates');
  assert.match(parkedFlush, /ingestClipIds\(ids\)/);

  // The SSE update branch must coalesce, never fetch one-by-one inline.
  const branch = html.slice(html.indexOf("if (d.type === 'update')"), html.indexOf("if (d.type === 'update')") + 260);
  assert.match(branch, /scheduleUpdateIngest\(d\.id\)/);
  assert.doesNotMatch(branch, /ingestClipById\(d\.id\)/);
});
