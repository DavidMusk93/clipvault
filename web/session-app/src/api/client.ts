import { z } from "zod";

/**
 * Session API v1 (SA-v1) client. Every response is parsed through a schema so a
 * backend change that breaks the contract fails loudly instead of rendering a
 * half-empty panel. Rust structs live in session/src/facade.rs.
 */

const Health = z
  .object({
    ok: z.boolean(),
    service: z.string().optional(),
    backend_id: z.string().optional(),
    role: z.string().optional(),
    corpus_id: z.string().optional(),
    events: z.number().nullable().optional(),
    last_ts: z.string().nullable().optional(),
  })
  .passthrough();

const Session = z
  .object({
    session_id: z.string(),
    event_count: z.number(),
    last_ts: z.string().nullable(),
    last_prompt: z.string().nullable().optional(),
    cwd: z.string().nullable().optional(),
    pinned_at: z.string().nullable().optional(),
    instance_id: z.string().nullable().optional(),
    source: z.string().nullable().optional(),
  })
  .passthrough();

const Sessions = z.object({ sessions: z.array(Session) });

const EventStub = z
  .object({
    event_id: z.string(),
    ts: z.string(),
    hook_event: z.string(),
    session_id: z.string().nullable().optional(),
    source: z.string().nullable().optional(),
    prompt: z.string().nullable().optional(),
    last_assistant_message: z.string().nullable().optional(),
    tool_name: z.string().nullable().optional(),
    llm_tool_name: z.string().nullable().optional(),
    tool_use_id: z.string().nullable().optional(),
    instance_id: z.string().nullable().optional(),
  })
  .passthrough();

const Events = z.object({ events: z.array(EventStub), view: z.string().optional() });

const PagedEvents = z.object({
  events: z.array(EventStub),
  has_more: z.boolean().optional(),
  next_cursor: z.object({ ts: z.string(), event_id: z.string() }).nullable().optional(),
});

const EventFull = z.object({ event: z.record(z.string(), z.unknown()) });

export type HealthT = z.infer<typeof Health>;
export type SessionT = z.infer<typeof Session>;
export type EventStubT = z.infer<typeof EventStub>;
export type PagedEventsT = z.infer<typeof PagedEvents>;
export type ToolCursor = { ts: string; event_id: string };

const BASE =
  typeof location !== "undefined" && location.pathname.startsWith("/trae") ? "/trae" : "";

async function get<T>(path: string, schema: z.ZodType<T>): Promise<T> {
  const res = await fetch(BASE + path, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  return schema.parse(await res.json());
}

export const api = {
  health: () => get("/api/health", Health),
  sessions: (limit = 80) => get(`/api/sessions?limit=${limit}`, Sessions),
  events: (sessionId: string) =>
    get(`/api/events?session_id=${encodeURIComponent(sessionId)}`, Events),
  /** Beats only (user / Stop / Notification) — small, never paginated. */
  beats: (sessionId: string) =>
    get(`/api/events?session_id=${encodeURIComponent(sessionId)}&view=beats`, Events),
  /** One page of the tool index (stubs), keyset by (ts, event_id). */
  eventsPaged: (sessionId: string, cursor: ToolCursor | null, limit = 500) => {
    const p = new URLSearchParams({
      session_id: sessionId,
      view: "tools",
      paged: "1",
      limit: String(limit),
    });
    if (cursor) {
      p.set("after_ts", cursor.ts);
      p.set("after", cursor.event_id);
    }
    return get(`/api/events?${p}`, PagedEvents);
  },
  /** Full body of one event (lazy; opened on demand). */
  event: (id: string) => get(`/api/event?id=${encodeURIComponent(id)}`, EventFull),
};

/** SSE stream URL (live `hook_event` stubs). */
export const streamUrl = () => `${BASE}/api/stream`;

/** Schemas exported for contract tests. */
export const schemas = {
  health: Health,
  sessions: Sessions,
  events: Events,
  pagedEvents: PagedEvents,
};
