/**
 * Trae sessions load state machine + local snapshot.
 * DuckDB remains the source of truth. localStorage is stale-while-revalidate
 * for first paint only. Never store tool bodies or secrets.
 */

export const PHASES = Object.freeze([
  'boot', 'cached', 'connecting', 'resync', 'live', 'paused', 'error',
]);

export const SNAP_KEY = 'cv.trae.snap.v1';
export const SNAP_VER = 1;
export const SNAP_MAX_BYTES = 450000;
export const SNAP_MAX_AGE_MS = 7 * 24 * 3600 * 1000;
export const RESYNC_FRESH_MS = 15000;

const EVENT_KEEP = [
  'event_id', 'ts', 'session_id', 'hook_event', 'source',
  'cwd', 'tool_name', 'llm_tool_name', 'tool_use_id', 'prompt',
  'last_assistant_message', 'notification_type', 'notification_message',
  'loop_count',
];

const SESS_KEEP = [
  'session_id', 'event_count', 'last_ts', 'last_prompt', 'cwd',
  'pinned_at', 'instance_id',
];

export function createLoadState() {
  return {
    phase: 'boot',
    paused: false,
    stream: 'closed',
    lastResyncAt: 0,
    lastError: '',
  };
}

export function canFetch(state) {
  return !!(state && !state.paused && state.phase !== 'paused');
}

export function canIngest(state) {
  return canFetch(state) && (state.phase === 'live' || state.phase === 'resync' || state.phase === 'cached');
}

export function reduce(state, event, now = Date.now()) {
  const prev = state || createLoadState();
  const next = { ...prev };
  const effects = [];
  const type = event && event.type;

  if (type === 'pause') {
    if (prev.phase === 'paused' && prev.paused) return { state: prev, effects };
    next.phase = 'paused';
    next.paused = true;
    next.stream = 'closed';
    effects.push('closeSSE', 'abortFetch', 'writeSnap');
    return { state: next, effects };
  }

  if (type === 'boot') {
    next.paused = false;
    next.phase = 'connecting';
    next.stream = 'connecting';
    effects.push('readSnap', 'setupSSE');
    return { state: next, effects };
  }

  if (type === 'resume') {
    next.paused = false;
    if (prev.stream === 'open' && prev.phase !== 'paused') {
      return { state: { ...prev, paused: false }, effects };
    }
    if (prev.stream === 'connecting' && !prev.paused) {
      return { state: { ...prev, paused: false }, effects };
    }
    next.phase = 'connecting';
    next.stream = 'connecting';
    effects.push('setupSSE');
    return { state: next, effects };
  }

  if (type === 'cache_hit') {
    if (prev.paused) return { state: prev, effects };
    if (prev.phase === 'boot' || prev.phase === 'connecting' || prev.phase === 'cached') {
      next.phase = 'cached';
    }
    return { state: next, effects };
  }

  if (type === 'stream_open') {
    if (next.paused) return { state: next, effects };
    next.stream = 'open';
    if (prev.phase === 'resync') return { state: next, effects };
    const fresh = prev.phase === 'live' && now - prev.lastResyncAt < RESYNC_FRESH_MS;
    if (fresh) {
      next.phase = 'live';
      return { state: next, effects };
    }
    next.phase = 'resync';
    effects.push('runResync');
    return { state: next, effects };
  }

  if (type === 'resync_start') {
    if (next.paused) return { state: next, effects };
    next.phase = 'resync';
    return { state: next, effects };
  }

  if (type === 'resync_ok') {
    if (next.paused) return { state: next, effects };
    next.phase = 'live';
    next.lastResyncAt = now;
    next.lastError = '';
    effects.push('writeSnap');
    return { state: next, effects };
  }

  if (type === 'resync_fail') {
    if (next.paused) return { state: next, effects };
    next.phase = 'error';
    next.lastError = String((event && event.reason) || 'resync');
    return { state: next, effects };
  }

  if (type === 'overflow') {
    if (next.paused) return { state: next, effects };
    next.phase = 'resync';
    effects.push('runResync');
    return { state: next, effects };
  }

  if (type === 'hook') {
    if (!canIngest(next)) return { state: next, effects };
    effects.push('ingest');
    return { state: next, effects };
  }

  return { state: next, effects };
}

function pick(obj, keys) {
  const out = {};
  if (!obj || typeof obj !== 'object') return out;
  for (const k of keys) {
    if (obj[k] != null && obj[k] !== '') out[k] = obj[k];
  }
  return out;
}

function isAsk(ev) {
  const n = String((ev && ev.tool_name) || '');
  const llm = String((ev && ev.llm_tool_name) || '');
  return n === 'AskUserQuestion' || llm === 'AskUserQuestion';
}

export function slimEvent(ev) {
  const row = pick(ev, EVENT_KEEP);
  if (isAsk(ev)) {
    if (ev.tool_input != null) row.tool_input = ev.tool_input;
    if (ev.tool_response != null) row.tool_response = ev.tool_response;
  }
  return row;
}

export function slimSession(s) {
  return pick(s, SESS_KEEP);
}

export function readSnap(storage, now = Date.now()) {
  if (!storage || typeof storage.getItem !== 'function') return null;
  let raw;
  try { raw = storage.getItem(SNAP_KEY); } catch { return null; }
  if (!raw) return null;
  try {
    const o = JSON.parse(raw);
    if (!o || o.v !== SNAP_VER) return null;
    if (typeof o.at !== 'number' || now - o.at > SNAP_MAX_AGE_MS || now - o.at < 0) return null;
    if (!Array.isArray(o.sessions) || !Array.isArray(o.events)) return null;
    if (o.current != null && typeof o.current !== 'string') return null;
    return {
      v: SNAP_VER,
      at: o.at,
      current: String(o.current || ''),
      sessions: o.sessions,
      events: o.events,
    };
  } catch {
    return null;
  }
}

export function writeSnap(storage, snap, now = Date.now()) {
  if (!storage || typeof storage.setItem !== 'function') return false;
  const sessions = (snap && snap.sessions ? snap.sessions : []).map(slimSession);
  let events = (snap && snap.events ? snap.events : []).map(slimEvent);
  const pack = () => JSON.stringify({
    v: SNAP_VER,
    at: now,
    current: String((snap && snap.current) || ''),
    sessions,
    events,
  });
  let raw = pack();
  while (raw.length > SNAP_MAX_BYTES && events.length > 24) {
    events = events.slice(Math.ceil(events.length / 4));
    raw = pack();
  }
  if (raw.length > SNAP_MAX_BYTES) {
    try { storage.removeItem(SNAP_KEY); } catch { /* ignore */ }
    return false;
  }
  try {
    storage.setItem(SNAP_KEY, raw);
    return true;
  } catch {
    try { storage.removeItem(SNAP_KEY); } catch { /* ignore */ }
    return false;
  }
}
