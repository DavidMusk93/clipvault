/**
 * Trae session load FSM + local snapshot. Source of truth stays DuckDB.
 * Run: node --test tests/session-load.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  createLoadState,
  reduce,
  canFetch,
  canIngest,
  readSnap,
  writeSnap,
  slimEvent,
  SNAP_KEY,
  SNAP_VER,
  RESYNC_FRESH_MS,
} from '../web/session-load.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

function memStore(init = {}) {
  const map = new Map(Object.entries(init));
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => { map.set(k, String(v)); },
    removeItem: (k) => { map.delete(k); },
    _map: map,
  };
}

test('boot connects and asks for a snapshot', () => {
  const { state, effects } = reduce(createLoadState(), { type: 'boot' });
  assert.equal(state.phase, 'connecting');
  assert.equal(state.stream, 'connecting');
  assert.deepEqual(effects, ['readSnap', 'setupSSE', 'runResync']);
});

test('cache_hit then stream_open still resyncs to confirm', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'boot' }).state;
  cur = reduce(cur, { type: 'cache_hit' }).state;
  assert.equal(cur.phase, 'cached');
  const { state, effects } = reduce(cur, { type: 'stream_open' }, 1_000);
  assert.equal(state.phase, 'resync');
  assert.deepEqual(effects, ['runResync']);
});

test('stream_open during an in-flight resync does not start another', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'boot' }).state;
  cur = reduce(cur, { type: 'resync_start' }).state;
  const { state, effects } = reduce(cur, { type: 'stream_open' }, 50);
  assert.equal(state.phase, 'resync');
  assert.equal(state.stream, 'open');
  assert.deepEqual(effects, []);
});

test('stream_open while live and fresh does not full resync', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'boot' }).state;
  cur = reduce(cur, { type: 'stream_open' }, 1_000).state;
  cur = reduce(cur, { type: 'resync_ok' }, 1_000).state;
  assert.equal(cur.phase, 'live');
  const { state, effects } = reduce(cur, { type: 'stream_open' }, 1_000 + RESYNC_FRESH_MS - 1);
  assert.equal(state.phase, 'live');
  assert.deepEqual(effects, []);
});

test('stream_open while live and stale resyncs', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'boot' }).state;
  cur = reduce(cur, { type: 'stream_open' }, 1_000).state;
  cur = reduce(cur, { type: 'resync_ok' }, 1_000).state;
  const { state, effects } = reduce(cur, { type: 'stream_open' }, 1_000 + RESYNC_FRESH_MS + 1);
  assert.equal(state.phase, 'resync');
  assert.deepEqual(effects, ['runResync']);
});

test('pause closes the stream and forbids fetch/ingest', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'boot' }).state;
  cur = reduce(cur, { type: 'stream_open' }, 5).state;
  cur = reduce(cur, { type: 'resync_ok' }, 5).state;
  const { state, effects } = reduce(cur, { type: 'pause' });
  assert.equal(state.phase, 'paused');
  assert.equal(state.paused, true);
  assert.ok(effects.includes('closeSSE'));
  assert.ok(effects.includes('writeSnap'));
  assert.equal(canFetch(state), false);
  assert.equal(canIngest(state), false);
  const hook = reduce(state, { type: 'hook' });
  assert.deepEqual(hook.effects, []);
});

test('resume from pause reconnects', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'pause' }).state;
  const { state, effects } = reduce(cur, { type: 'resume' });
  assert.equal(state.phase, 'connecting');
  assert.equal(state.paused, false);
  assert.deepEqual(effects, ['setupSSE']);
});

test('overflow forces resync; fail lands in error', () => {
  let cur = createLoadState();
  cur = reduce(cur, { type: 'boot' }).state;
  cur = reduce(cur, { type: 'stream_open' }, 1).state;
  cur = reduce(cur, { type: 'resync_ok' }, 1).state;
  const over = reduce(cur, { type: 'overflow' });
  assert.equal(over.state.phase, 'resync');
  assert.deepEqual(over.effects, ['runResync']);
  const fail = reduce(over.state, { type: 'resync_fail', reason: 'events' });
  assert.equal(fail.state.phase, 'error');
  assert.equal(canIngest(fail.state), false);
});

test('snapshot roundtrip strips tool bodies except Ask', () => {
  const store = memStore();
  const ok = writeSnap(store, {
    current: 'abc',
    sessions: [{ session_id: 'abc', event_count: 3, last_ts: '2026-09-08 01:00:00', last_prompt: 'hi', extra: 'drop' }],
    events: [
      { event_id: '1', hook_event: 'UserPromptSubmit', prompt: 'hi', ts: 't1' },
      { event_id: '2', hook_event: 'PostToolUse', tool_name: 'RunCommand', tool_input: { cmd: 'rg' }, tool_response: { output: 'huge' }, ts: 't2' },
      { event_id: '3', hook_event: 'PreToolUse', tool_name: 'AskUserQuestion', tool_input: { questions: [1] }, ts: 't3' },
    ],
  }, 1_700_000_000_000);
  assert.equal(ok, true);
  const snap = readSnap(store, 1_700_000_000_000);
  assert.equal(snap.v, SNAP_VER);
  assert.equal(snap.current, 'abc');
  assert.equal(snap.sessions[0].extra, undefined);
  assert.equal(snap.events[1].tool_response, undefined);
  assert.equal(snap.events[1].tool_input, undefined);
  assert.deepEqual(snap.events[2].tool_input, { questions: [1] });
  const tool = slimEvent({ hook_event: 'PostToolUse', tool_name: 'RunCommand', tool_response: { output: 'x' } });
  assert.equal(tool.tool_response, undefined);
});

test('snapshot rejects old, wrong version, and missing arrays', () => {
  const now = 1_700_000_000_000;
  const store = memStore({
    [SNAP_KEY]: JSON.stringify({ v: 1, at: now - 8 * 24 * 3600 * 1000, current: '', sessions: [], events: [] }),
  });
  assert.equal(readSnap(store, now), null);
  store.setItem(SNAP_KEY, JSON.stringify({ v: 2, at: now, sessions: [], events: [] }));
  assert.equal(readSnap(store, now), null);
  store.setItem(SNAP_KEY, JSON.stringify({ v: 1, at: now, sessions: [] }));
  assert.equal(readSnap(store, now), null);
  store.setItem(SNAP_KEY, 'not-json');
  assert.equal(readSnap(store, now), null);
});

test('sessions.html imports the load machine and does not resync on every onopen', () => {
  const html = fs.readFileSync(path.join(root, 'trae_hooks/web/sessions.html'), 'utf8');
  const agents = fs.readFileSync(path.join(root, 'AGENTS.md'), 'utf8');
  const taste = fs.readFileSync(path.join(root, 'docs/design-taste.md'), 'utf8');
  const check = fs.readFileSync(path.join(root, 'scripts/check-frontend.sh'), 'utf8');
  assert.match(html, /from \"\.\/session-load\.mjs\"/);
  assert.match(html, /createLoadState/);
  assert.match(html, /reduce\(/);
  assert.match(html, /readSnap/);
  assert.match(html, /writeSnap/);
  assert.match(html, /trae_sessions_fsm/);
  assert.match(html, /paintFromLive\(\"cache\"\)/);
  assert.doesNotMatch(html, /es\.onopen = \(\) => scheduleResync\(\)/);
  assert.match(agents, /session-load\.mjs/);
  assert.match(taste, /先画上次快照/);
  assert.match(check, /session-load\.test\.mjs/);
});
