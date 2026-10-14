/**
 * SSE leader-election gate — executes the real election code on a virtual clock.
 *
 * 2026-10-14 (mac-work): one socket churn per minute. Live metrics: `sse_state` role
 * leader -> follow ×8/×7 in 17 min, server `phase=drop` ~1/min, `proc_sample.sse`
 * oscillating 1 <-> 2. This file reproduces it deterministically and pins the fix:
 * with a *hidden* leader whose 1s heartbeat Chrome throttles to ~60s, the visible tab
 * used to re-claim (2 sockets, then yield), and now simply follows.
 *
 * Run via scripts/check-frontend.sh (listed in the gates comment).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';
import { fnSource, runElectionScenario } from './helpers/sse-election.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

test('sse-election gate is registered in check-frontend.sh', () => {
  assert.match(check, /sse-election\.test\.mjs/);
});

test('a throttled hidden leader keeps the single socket (no per-minute churn)', () => {
  const r = runElectionScenario(html, { runMs: 200000 });
  const [a, b] = r.tabs;
  assert.equal(a.hidden, true);
  assert.equal(b.hidden, false);
  // The regression: B claimed, opened a second EventSource, then yielded to A's
  // throttled beat -> opens=3 closes=3 in 200s on the old code.
  assert.equal(b.yields.length ?? b.yields, 0, 'a visible follower must not yield to a slow heartbeat');
  assert.equal(b.opens, 0, 'a healthy leader means the follower opens no socket at all');
  assert.equal(r.maxConcurrentSockets, 1, 'exactly one EventSource across tabs');
  assert.equal(r.socketsNow, 1);
  assert.equal(a.opens, 1, 'the leader keeps one socket for the whole run');
  assert.equal(a.leaderNow, true);
});

test('a frozen leader hands the socket over once, not once per minute', () => {
  const r = runElectionScenario(html, {
    runMs: 200000,
    tabs: [
      { name: 'A', id: 'aaa', hidden: true, freezeUntilMs: 40000 },
      { name: 'B', id: 'bbb', hidden: false },
    ],
  });
  const [a, b] = r.tabs;
  // B cannot get an answer while A is frozen, so B claims (that is correct), and once A
  // wakes it yields to the *visible* tab instead of seizing the socket back.
  assert.equal(r.totalYields, 1, 'exactly one hand-off, no oscillation');
  assert.equal(b.leaderNow, true, 'the visible tab holds the socket after the hand-off');
  assert.equal(a.leaderNow, false);
  assert.equal(r.socketsNow, 1, 'never two sockets left behind');
  assert.ok(r.maxConcurrentSockets <= 2, 'overlap is a hand-off, not a stampede');
});

test('two visible tabs settle on one leader', () => {
  const r = runElectionScenario(html, {
    runMs: 120000,
    tabs: [
      { name: 'A', id: 'aaa', hidden: false },
      { name: 'B', id: 'bbb', hidden: false },
    ],
  });
  assert.equal(r.socketsNow, 1);
  assert.ok(r.totalYields <= 2, `settling must converge, got ${r.totalYields} yields`);
  assert.equal(r.tabs.filter((t) => t.leaderNow).length, 1, 'exactly one leader');
  // The older tab (smaller id) wins an equal-role tie-break.
  assert.equal(r.tabs[0].leaderNow, true);
});

test('the probe is answered event-driven, not by a throttled timer', () => {
  assert.match(html, /m\.t === 'probe'[\s\S]{0,200}sseBeat\(\)/);
  assert.match(html, /m\.t === 'lead'[\s\S]{0,200}sseYieldToPeer\(/);
  // `>=`: an answer landing in the same millisecond as the probe still counts, otherwise
  // a fast peer looks absent and the prober claims anyway (harness caught this).
  assert.match(fnSource(html, 'probeThenClaim'), /sseLeadAt >= askedAt/);
});
