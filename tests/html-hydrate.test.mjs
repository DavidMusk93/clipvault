/**
 * Hydrate batching / race gate.
 *
 * `flushHtmlHydrate` is inline in web/index.html, so extract the real function
 * and drive it with stubs. Covers: one relayout per batch, partial/empty bodies,
 * rejected fetches must release in-flight ids, and detached cards must not throw.
 *
 * Run: node --test tests/html-hydrate.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexHtml = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');

/** Pull `function name(...) { ... }` out of the inline script (brace-matched). */
function extractFunctionSource(src, name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in index.html`);
  const open = src.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error(`${name} has unbalanced braces`);
}

const flushSrc = extractFunctionSource(indexHtml, 'flushHtmlHydrate');

function buildFlush(state) {
  const factory = new Function(
    'htmlHydrateTimer',
    'htmlHydratePending',
    'fetchClipsByIds',
    'htmlHydrating',
    'clips',
    'cardCache',
    'repaintCardBody',
    'window',
    `${flushSrc}\nreturn flushHtmlHydrate;`,
  );
  return factory(
    state.timer ?? null,
    state.pending,
    state.fetchClipsByIds,
    state.hydrating,
    state.clips,
    state.cardCache,
    state.repaintCardBody,
    state.window,
  );
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

function traceRelayout() {
  const calls = [];
  return {
    calls,
    window: { ClipViewMasonry: { relayout: () => calls.push('relayout') } },
  };
}

test('one batch repaints every body and re-packs masonry a single time', async () => {
  const pending = new Map([
    ['a', { item: { id: 'a' }, card: { id: 'card-a' } }],
    ['b', { item: { id: 'b' }, card: { id: 'card-b' } }],
  ]);
  const hydrating = new Set(['a', 'b']);
  const clips = [{ id: 'a' }, { id: 'b' }];
  const cardCache = new Map([['a', {}], ['b', {}]]);
  const relayout = traceRelayout();
  const repainted = [];
  buildFlush({
    pending,
    hydrating,
    clips,
    cardCache,
    fetchClipsByIds: async () => [
      { id: 'a', htmlContent: '<p>A</p>' },
      { id: 'b', htmlContent: '<p>B</p>' },
    ],
    repaintCardBody: (el, live) => repainted.push(live.id),
    window: relayout.window,
  })();
  await tick();
  assert.deepEqual(repainted.sort(), ['a', 'b']);
  assert.equal(clips[0].htmlContent, '<p>A</p>');
  assert.equal(clips[1].htmlContent, '<p>B</p>');
  assert.equal(clips[0].htmlOmitted, false);
  assert.equal(pending.size, 0);
  assert.equal(hydrating.size, 0, 'in-flight ids released');
  assert.deepEqual(relayout.calls, ['relayout'], 'exactly one re-pack for the batch');
});

test('a short/empty body repaints only what arrived, still releases ids', async () => {
  const pending = new Map([
    ['a', { item: { id: 'a' }, card: { id: 'card-a' } }],
    ['b', { item: { id: 'b' }, card: { id: 'card-b' } }],
  ]);
  const hydrating = new Set(['a', 'b']);
  const clips = [{ id: 'a' }, { id: 'b' }];
  const relayout = traceRelayout();
  const repainted = [];
  buildFlush({
    pending,
    hydrating,
    clips,
    cardCache: new Map(),
    fetchClipsByIds: async () => [{ id: 'a', htmlContent: '<p>A</p>' }, { id: 'b' }],
    repaintCardBody: (el, live) => repainted.push(live.id),
    window: relayout.window,
  })();
  await tick();
  assert.deepEqual(repainted, ['a']);
  assert.equal(clips[1].htmlContent, undefined, 'empty row is left alone');
  assert.equal(hydrating.size, 0);
  assert.deepEqual(relayout.calls, ['relayout']);
});

test('a rejected batch releases every in-flight id (no stuck hydrating)', async () => {
  const pending = new Map([
    ['a', { item: { id: 'a' }, card: {} }],
    ['b', { item: { id: 'b' }, card: {} }],
  ]);
  const hydrating = new Set(['a', 'b']);
  const relayout = traceRelayout();
  buildFlush({
    pending,
    hydrating,
    clips: [],
    cardCache: new Map(),
    fetchClipsByIds: async () => { throw new Error('network'); },
    repaintCardBody: () => { throw new Error('must not repaint on failure'); },
    window: relayout.window,
  })();
  await tick();
  assert.equal(hydrating.size, 0, 'released so a later reset can retry');
  assert.equal(pending.size, 0);
  assert.deepEqual(relayout.calls, []);
});

test('a detached card without a cache entry is skipped without throwing', async () => {
  const pending = new Map([['a', { item: { id: 'a' }, card: undefined }]]);
  const hydrating = new Set(['a']);
  const relayout = traceRelayout();
  let repainted = 0;
  buildFlush({
    pending,
    hydrating,
    clips: [],
    cardCache: new Map(),
    fetchClipsByIds: async () => [{ id: 'a', htmlContent: '<p>A</p>' }],
    repaintCardBody: () => { repainted += 1; },
    window: relayout.window,
  })();
  await tick();
  assert.equal(repainted, 0);
  assert.equal(hydrating.size, 0);
  assert.deepEqual(relayout.calls, []);
});

test('an empty pending map short-circuits without fetching', async () => {
  let fetched = 0;
  const hydrating = new Set();
  buildFlush({
    pending: new Map(),
    hydrating,
    clips: [],
    cardCache: new Map(),
    fetchClipsByIds: async () => { fetched += 1; return []; },
    repaintCardBody: () => {},
    window: {},
  })();
  await tick();
  assert.equal(fetched, 0);
});
