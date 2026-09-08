/* ClipVault notes metrics — local POST /api/ui-metrics only. No content. */
(function () {
  const FORBIDDEN = /^(body|title|markdown|text|content|html|query|q|search|note|src|md|excerpt|url)$/i;
  const ALLOW = new Set([
    'mode', 'ratio', 'chars', 'bytes', 'n', 'value', 'interaction', 'q_len',
    'kind', 'phase', 'reason', 'lag', 'host', 'w', 'h', 'nodes', 'dy',
  ]);
  const NAME = /^[a-z][a-z0-9_]{1,63}$/;
  const SESSION_KEY = 'clipvault.metrics.session';

  function sessionId() {
    try {
      let s = sessionStorage.getItem(SESSION_KEY);
      if (!s) {
        s = (crypto.randomUUID && crypto.randomUUID()) || String(Date.now());
        sessionStorage.setItem(SESSION_KEY, s);
      }
      return s;
    } catch (_) {
      return 'anon';
    }
  }

  function cleanPayload(raw) {
    if (!raw || typeof raw !== 'object') return undefined;
    const out = {};
    for (const [k, v] of Object.entries(raw)) {
      if (FORBIDDEN.test(k)) return null;
      if (!ALLOW.has(k)) continue;
      if (typeof v === 'string') {
        if (v.length > 32) return null;
        out[k] = v;
      } else if (typeof v === 'number' && Number.isFinite(v)) {
        out[k] = v;
      } else if (typeof v === 'boolean') {
        out[k] = v;
      }
    }
    return out;
  }

  const queue = [];
  const RING_MAX = 80;
  const ring = [];
  let flushTimer = 0;
  let panelOpen = false;
  let lastInputAt = 0;

  function flush() {
    flushTimer = 0;
    if (!queue.length) return;
    const events = queue.splice(0, 100);
    const api = (typeof API === 'string' ? API : '') + '/api/ui-metrics';
    const body = JSON.stringify({ events, session: sessionId() });
    try {
      if (navigator.sendBeacon) {
        const blob = new Blob([body], { type: 'application/json' });
        if (navigator.sendBeacon(api, blob)) return;
      }
    } catch (_) {}
    fetch(api, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      keepalive: true,
    }).catch(() => {});
  }

  function emit(name, extra) {
    if (!NAME.test(name)) return;
    const payload = extra && extra.payload !== undefined ? cleanPayload(extra.payload) : undefined;
    if (payload === null) return;
    const ev = { name, ts: Date.now(), session: sessionId() };
    if (extra && extra.dur_ms != null && Number.isFinite(extra.dur_ms)) ev.dur_ms = extra.dur_ms;
    if (extra && typeof extra.ok === 'boolean') ev.ok = extra.ok;
    if (payload && Object.keys(payload).length) ev.payload = payload;
    queue.push(ev);
    ring.push(ev);
    if (ring.length > RING_MAX) ring.splice(0, ring.length - RING_MAX);
    const hot = name.startsWith('trae_') || name.startsWith('wall_') || name.startsWith('sse_')
      || name.startsWith('sheet_') || name === 'notes_cls' || name === 'notes_longtask' || name === 'notes_open'
      || name === 'chrome_shift' || name === 'wall_cls';
    if (hot) flush();
    else if (queue.length >= 20) flush();
    else if (!flushTimer) flushTimer = setTimeout(flush, 2000);
  }

  function setOpen(open) {
    panelOpen = !!open;
  }

  function noteInput() {
    lastInputAt = Date.now();
  }

  let clsObs;
  let ltObs;
  let etObs;

  function startObservers(root) {
    stopObservers();
    if (typeof PerformanceObserver === 'undefined') return;
    try {
      clsObs = new PerformanceObserver((list) => {
        if (!panelOpen) return;
        for (const e of list.getEntries()) {
          if (!e.hadRecentInput && e.value > 0.001) {
            const inPanel = (e.sources || []).some((s) => root && root.contains(s.node));
            if (inPanel || !(e.sources || []).length) {
              const morphing = !!(root && root.classList.contains('open') && !root.classList.contains('is-settled'));
              const src = (e.sources || [])[0];
              const node = src && src.node;
              let kind = '';
              if (node) {
                const klass = (node.getAttribute && node.getAttribute('class')) || '';
                kind = String(node.id || klass || node.nodeName || '').replace(/\s+/g, '.').slice(0, 32);
              }
              emit('notes_cls', {
                dur_ms: e.value * 1000,
                payload: {
                  value: Math.round(e.value * 10000) / 10000,
                  phase: morphing ? 'morph' : 'live',
                  kind,
                },
              });
            }
          }
        }
      });
      clsObs.observe({ type: 'layout-shift', buffered: false });
    } catch (_) {}
    try {
      ltObs = new PerformanceObserver((list) => {
        if (!panelOpen) return;
        for (const e of list.getEntries()) {
          if (Date.now() - lastInputAt < 2000 && e.duration >= 50) {
            emit('notes_longtask', { dur_ms: e.duration });
          }
        }
      });
      ltObs.observe({ type: 'longtask', buffered: false });
    } catch (_) {}
    try {
      etObs = new PerformanceObserver((list) => {
        if (!panelOpen || !root) return;
        for (const e of list.getEntries()) {
          const t = e.target;
          if (t && root.contains(t) && e.duration >= 16) {
            const kind = String(e.name || '').slice(0, 24);
            emit('notes_inp', { dur_ms: e.duration, payload: { interaction: kind } });
          }
        }
      });
      etObs.observe({ type: 'event', buffered: false, durationThreshold: 16 });
    } catch (_) {}
  }

  function stopObservers() {
    try { clsObs && clsObs.disconnect(); } catch (_) {}
    try { ltObs && ltObs.disconnect(); } catch (_) {}
    try { etObs && etObs.disconnect(); } catch (_) {}
    clsObs = ltObs = etObs = null;
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flush();
  });
  window.addEventListener('pagehide', flush);

  globalThis.ClipNotesMetrics = {
    emit,
    flush,
    setOpen,
    noteInput,
    startObservers,
    stopObservers,
    sessionId,
    recentLocal() { return ring.slice(); },
  };
})();
