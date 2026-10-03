/**
 * Session-panel telemetry (ui metrics). Mirrors the vanilla `emit`/`flushMetrics`
 * contract so the 调试 panel and the parent's `/api/ui-metrics` keep working:
 * a small ring for the panel, a queue batched to the parent (embedded) or
 * POSTed directly (standalone). Key names only — never message content.
 *
 * `ui-track.js` / `metrics-panel.js` are loaded as globals by the shell
 * (`trae_hooks/web/sessions.html`), like the vanilla panel did.
 */

export type Metric = {
  name: string;
  ts: number;
  dur_ms?: number;
  value?: number;
  ok?: boolean;
  trace?: string;
  payload?: Record<string, number | string>;
};

export type EmitExtra = {
  dur_ms?: number;
  value?: number;
  ok?: boolean;
  trace?: string;
  payload?: Record<string, number | string>;
};

type MetricsCtl = {
  setOpen: (open: boolean) => void;
  toggle: () => void;
  noteIncoming: () => void;
  paintBadge: () => void;
  slowCount: () => number;
  destroy: () => void;
  family: string;
};

type ClipGlobals = {
  ClipUiTrack?: {
    install?: (sink: (name: string, extra?: EmitExtra) => void, opts?: { zone?: string }) => void;
  };
  ClipMetricsPanel?: {
    create?: (opts: {
      family: string;
      mount: HTMLElement;
      getLocal: () => Metric[];
    }) => MetricsCtl | null;
  };
};

const g = globalThis as unknown as ClipGlobals;
const METRICS_URL = "http://127.0.0.1:8080/api/ui-metrics";
const RING_MAX = 80;
const NAME_RE = /^[a-z][a-z0-9_]{1,63}$/;
const PAYLOAD_RE =
  /^(mode|ratio|chars|bytes|n|value|interaction|q_len|kind|phase|reason|lag|host|w|h|nodes|compiled|reused|zone|action|target|via)$/;

const ring: Metric[] = [];
const queue: Metric[] = [];
let flushTimer = 0;
let panel: MetricsCtl | null = null;

const newTrace = () => {
  try {
    return crypto.randomUUID().replace(/-/g, "").slice(0, 16);
  } catch {
    return Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-6);
  }
};
let trace = newTrace();

export const setTrace = (next?: string) => {
  trace = next || newTrace();
};

const slimPayload = (payload?: Record<string, number | string>) => {
  if (!payload) return undefined;
  const out: Record<string, number | string> = {};
  for (const [k, v] of Object.entries(payload)) {
    if (!PAYLOAD_RE.test(k)) continue;
    if (typeof v === "number" && Number.isFinite(v)) out[k] = v;
    else if (typeof v === "string" && v.length <= 32) out[k] = v;
  }
  return Object.keys(out).length ? out : undefined;
};

export const emit = (name: string, extra: EmitExtra = {}) => {
  if (!NAME_RE.test(name)) return;
  const ev: Metric = { name, ts: Date.now() };
  if (extra.dur_ms != null && Number.isFinite(extra.dur_ms)) ev.dur_ms = extra.dur_ms;
  if (extra.value != null && Number.isFinite(extra.value)) ev.value = extra.value;
  if (typeof extra.ok === "boolean") ev.ok = extra.ok;
  ev.trace = extra.trace ? String(extra.trace).slice(0, 64) : trace;
  const payload = slimPayload(extra.payload);
  if (payload) ev.payload = payload;
  ring.push(ev);
  if (ring.length > RING_MAX) ring.splice(0, ring.length - RING_MAX);
  queue.push(ev);
  panel?.noteIncoming();
  if (queue.length >= 60) flush();
  else if (!flushTimer) flushTimer = window.setTimeout(flush, 400);
};

const sendBatch = (events: Metric[]) => {
  const body = JSON.stringify({ events, session: "trae-sessions" });
  const embedded = typeof window !== "undefined" && window.parent !== window;
  try {
    if (embedded) {
      window.parent.postMessage(
        { type: "clipvault-ui-metrics", events, session: "trae-sessions" },
        location.origin,
      );
      return;
    }
  } catch {
    /* fall through to a direct POST */
  }
  try {
    if (navigator.sendBeacon) {
      const blob = new Blob([body], { type: "application/json" });
      if (navigator.sendBeacon(METRICS_URL, blob)) return;
    }
  } catch {
    /* fall through */
  }
  fetch(METRICS_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
    keepalive: true,
  }).catch(() => {});
};

export const flush = () => {
  flushTimer = 0;
  while (queue.length) sendBatch(queue.splice(0, 100));
};

export const getLocal = () => ring.slice();

/** Wire ui-track + flush-on-hide. Call once at boot. */
export const installTelemetry = () => {
  g.ClipUiTrack?.install?.(emit, { zone: "sessions" });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flush();
  });
  window.addEventListener("pagehide", flush);
  // Layout shift + long tasks: the two numbers the 调试 panel diagnoses.
  try {
    if (typeof PerformanceObserver !== "undefined") {
      const cls = new PerformanceObserver((list) => {
        let max = 0;
        for (const entry of list.getEntries() as (PerformanceEntry & {
          value?: number;
          hadRecentInput?: boolean;
        })[]) {
          if (entry.hadRecentInput) continue;
          if ((entry.value ?? 0) > max) max = entry.value ?? 0;
        }
        if (max > 0) emit("trae_sessions_cls", { value: max });
      });
      cls.observe({ type: "layout-shift", buffered: true });
      const lt = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          emit("trae_sessions_longtask", { dur_ms: entry.duration });
        }
      });
      lt.observe({ type: "longtask", buffered: false });
    }
  } catch {
    /* observer unsupported */
  }
};

/** Mount the 调试 float into the corner stack; returns a teardown. */
export const mountMetricsPanel = (el: HTMLElement) => {
  panel = g.ClipMetricsPanel?.create?.({ family: "sessions", mount: el, getLocal }) ?? null;
  return () => {
    panel?.destroy();
    panel = null;
  };
};
