/**
 * SSE leader-election harness with a virtual clock and a fake BroadcastChannel.
 *
 * Why: the 2026-10-14 churn (one socket close/open per minute) only reproduced with
 * two tabs where the *leader* was hidden — Chrome throttles a background tab's 1s
 * heartbeat, so the visible follower judged the claim stale and re-claimed. That is a
 * timer + message interaction, so it needs a clock we control, not a real browser.
 *
 * `runElectionScenario(html)` loads the real election functions out of a given
 * `web/index.html` revision (old revisions load fine: only the functions present are
 * extracted), runs the scenario, and reports what each tab did.
 */

/** Brace-matched `function name(...) { ... }` (keeps a leading `async`). */
export function fnSource(html, name) {
  let start = html.indexOf(`function ${name}(`);
  if (start < 0) return null;
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

/**
 * Brace-matched arrow assigned to `<assignee> = (...) => { ... };`.
 * The BroadcastChannel handler is a top-level assignment, so it is not reachable
 * through `fnSource` — and without it the harness would deliver no messages at all.
 */
export function arrowSource(html, assignee) {
  const at = html.indexOf(`${assignee} = `);
  if (at < 0) return null;
  const start = html.indexOf('(', at);
  let depth = 0;
  const open = html.indexOf('{', html.indexOf('=>', start));
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth += 1;
    else if (html[i] === '}') {
      depth -= 1;
      if (depth === 0) {
        const semi = html.indexOf(';', i);
        return html.slice(start, semi > 0 ? semi : i + 1);
      }
    }
  }
  throw new Error(`${assignee} has unbalanced braces`);
}

/** Numeric constants live at module scope in index.html; mirror them into the harness. */
function constNumber(html, name, fallback) {
  const m = new RegExp(`const ${name} = (\\d+);`).exec(html);
  return m ? Number(m[1]) : fallback;
}

class Clock {
  constructor() { this.now = 0; this.tasks = new Map(); this.seq = 1; }
  at(ms, fn, every = 0) {
    const id = this.seq++;
    this.tasks.set(id, { at: this.now + ms, fn, every });
    return id;
  }
  clear(id) { this.tasks.delete(id); }
  run(untilMs, { step = 5 } = {}) {
    while (this.now <= untilMs) {
      let next = null;
      for (const [id, t] of this.tasks) {
        if (t.at <= this.now && (!next || t.at < next.t.at)) next = { id, t };
      }
      if (!next) {
        const soonest = [...this.tasks.values()].reduce((a, t) => (a == null || t.at < a ? t.at : a), null);
        if (soonest == null) { this.now = untilMs; return; }
        this.now = Math.max(this.now + step, soonest);
        continue;
      }
      const { id, t } = next;
      if (t.every) t.at = this.now + t.every;
      else this.tasks.delete(id);
      t.fn();
    }
  }
}

export function runElectionScenario(html, opts = {}) {
  const runMs = opts.runMs ?? 180000;
  /** A visible tab re-runs the election when the user activates it (focus/visibility). */
  const activateEveryMs = opts.activateEveryMs ?? 30000;
  /** Browser throttles a hidden tab's 1s heartbeat to this granularity. */
  const hiddenHeartbeatMs = opts.hiddenHeartbeatMs ?? 60000;
  /** Short id = older tab, which wins an equal-role tie-break. */
  const specs = opts.tabs ?? [
    { name: 'A', id: 'aaa', hidden: true },
    { name: 'B', id: 'bbb', hidden: false },
  ];

  const clock = new Clock();
  const log = [];
  const tabs = [];
  const live = { n: 0, max: 0 };

  const deliver = (from, msg) => {
    for (const t of tabs) {
      if (t.name === from) continue;
      // A frozen page processes nothing until it wakes (pessimistic: no backlog).
      if (t.freezeUntilMs && clock.now < t.freezeUntilMs) continue;
      clock.at(0, () => { if (t.bc.onmessage) t.bc.onmessage({ data: msg }); });
    }
  };

  function makeTab(spec) {
    const tab = {
      name: spec.name,
      hidden: spec.hidden,
      tabId: spec.id,
      freezeUntilMs: spec.freezeUntilMs || 0,
      sockets: 0,
      opens: 0,
      closes: 0,
      resyncs: 0,
      roles: [],
      yields: [],
      live: false,
      bc: null,
      sseDebug: { wall: { role: '' } },
      document: {
        get visibilityState() { return tab.hidden ? 'hidden' : 'visible'; },
      },
    };
    tab.bc = { postMessage: (msg) => deliver(tab.name, msg) };
    tab.setupSSE = () => { if (tab.live) return; tab.live = true; tab.opens += 1; live.n += 1; live.max = Math.max(live.max, live.n); };
    tab.teardownSSE = () => { if (!tab.live) return; tab.live = false; tab.closes += 1; live.n -= 1; };
    tab.sseIsFresh = () => tab.live;
    const nm = (name, extra) => {
      if (name !== 'sse_state') return;
      const reason = (extra && extra.payload && extra.payload.reason) || '';
      if (reason) {
        tab.roles.push(`${clock.now}:${reason}`);
        if (reason === 'follow' || reason === 'solo_hidden') tab.yields.push(clock.now);
      }
      log.push(`${clock.now} ${tab.name} role=${reason}`);
    };

    const names = ['sseRoleMsg', 'sseYieldToPeer', 'sseBeat', 'probeThenClaim', 'yieldSocket', 'setSseLeader', 'considerElect', 'noteSseYield']
      .map((n) => fnSource(html, n))
      .filter(Boolean);
    const handler = arrowSource(html, 'sseBc.onmessage');
    const body = [
      'const document = deps.document;',
      'const window = deps.window;',
      'const Date = deps.Date;',
      'const nm = deps.nm;',
      'const sseDebug = deps.sseDebug;',
      'const sseBc = deps.bc;',
      'const sseTabId = deps.tabId;',
      'const setupSSE = deps.setupSSE;',
      'const teardownSSE = deps.teardownSSE;',
      'const sseIsFresh = deps.sseIsFresh;',
      'const noteSSEEvent = deps.noteSSEEvent;',
      'const ingestSSEPayload = deps.ingestSSEPayload;',
      'const scheduleResync = deps.scheduleResync;',
      'const performance = { now: () => deps.now() };',
      'let wallBootInflight = false;',
      'let lastWallFetchAt = 0;',
      `const SSE_LEAD_TTL_MS = ${constNumber(html, 'SSE_LEAD_TTL_MS', 2500)};`,
      `const SSE_PROBE_MS = ${constNumber(html, 'SSE_PROBE_MS', 0)};`,
      'let sseLeader = false;',
      'let sseLeadAt = 0;',
      'let sseElectTimer = 0;',
      'let sseBeatTimer = 0;',
      'let lastSseYieldAt = 0;',
      ...names,
      handler ? `const handleBC = ${handler};` : 'const handleBC = () => {};',
      `return {
        considerElect, setSseLeader, sseBeat, handleBC,
        get leader() { return sseLeader; },
        get leadAt() { return sseLeadAt; },
      };`,
    ].join('\n');

    tab.api = new Function('deps', body)({
      document: tab.document,
      Date: { now: () => clock.now },
      window: {
        setTimeout: (fn, ms) => clock.at(ms, fn),
        clearTimeout: (id) => clock.clear(id),
        setInterval: (fn, ms) => clock.at(ms, fn, tab.hidden ? Math.max(ms, hiddenHeartbeatMs) : ms),
        clearInterval: (id) => clock.clear(id),
      },
      nm,
      sseDebug: tab.sseDebug,
      bc: tab.bc,
      tabId: tab.tabId,
      setupSSE: tab.setupSSE,
      teardownSSE: tab.teardownSSE,
      sseIsFresh: tab.sseIsFresh,
      noteSSEEvent: () => {},
      ingestSSEPayload: () => {},
      scheduleResync: () => { tab.resyncs += 1; },
      now: () => clock.now,
    });
    tab.bc.onmessage = (ev) => tab.api.handleBC(ev);
    return tab;
  }

  // Tabs boot 1s apart (a real second window lands after the first one settled).
  let bootAt = 0;
  for (const spec of specs) {
    const tab = makeTab(spec);
    tabs.push(tab);
    const at = bootAt;
    clock.at(at + 100, () => tab.api.considerElect());
    if (!spec.hidden) {
      // The user keeps activating the visible tab (focus / visibilitychange).
      clock.at(at + 200, () => tab.api.considerElect(), activateEveryMs);
    }
    bootAt += 1000;
  }

  clock.run(runMs, { step: 5 });

  return {
    log,
    tabs: tabs.map((t) => ({
      name: t.name,
      hidden: t.hidden,
      opens: t.opens,
      closes: t.closes,
      roles: t.roles.length,
      yields: t.yields.length,
      resyncs: t.resyncs,
      leaderNow: t.api.leader,
    })),
    totalYields: tabs.reduce((n, t) => n + t.yields.length, 0),
    totalOpens: tabs.reduce((n, t) => n + t.opens, 0),
    maxConcurrentSockets: live.max,
    socketsNow: live.n,
  };
}
