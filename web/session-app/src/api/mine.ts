import { useQuery } from "@tanstack/react-query";
import { z } from "zod";

/** `/api/mine?format=full` (Session Analysis v2). Permissive: the Rust struct is
 *  the source, this only types the fields the sheet reads. */

const Chart = z.object({
  kind: z.string(),
  label: z.string(),
  value: z.string(),
  unit: z.string().optional(),
});

const Table = z.object({
  caption: z.string().optional(),
  cols: z.array(z.object({ id: z.string(), title: z.string() })).optional(),
  rows: z.array(z.record(z.string(), z.unknown())).optional(),
  chart: Chart.optional(),
});

const Block = z
  .object({
    title: z.string(),
    axis: z.string(),
    note: z.string().optional(),
    table: Table.optional(),
    tables: z.array(Table).optional(),
  })
  .passthrough();

const Metric = z
  .object({
    id: z.string(),
    label: z.string(),
    unit: z.string(),
    dir: z.string(),
    target: z.number().nullable().optional(),
    value: z.union([z.number(), z.string()]).nullable(),
    baseline: z.union([z.number(), z.string()]).nullable().optional(),
    delta: z.number().nullable().optional(),
    note: z.string().optional(),
  })
  .passthrough();

const Loss = z
  .object({
    id: z.string(),
    label: z.string(),
    s: z.number(),
    usd: z.number(),
    kind: z.string(),
    how: z.string().optional(),
  })
  .passthrough();

const Ref = z
  .object({
    turn: z.number().nullable().optional(),
    label: z.string().optional(),
    exit_code: z.union([z.number(), z.string()]).nullable().optional(),
    event_id: z.string().optional(),
  })
  .passthrough();

const Finding = z
  .object({
    id: z.string(),
    sev: z.string(),
    axis: z.string().optional(),
    title: z.string(),
    text: z.string().optional(),
    cause: z.string().optional(),
    action: z.string().optional(),
    gate: z.string().optional(),
    draft: z.string().optional(),
    impact: z.object({ s: z.number(), usd: z.number(), kind: z.string() }),
    metric: z
      .object({
        id: z.string().optional(),
        now: z.unknown(),
        target: z.unknown(),
        unit: z.string().optional(),
        dir: z.string().optional(),
      })
      .nullable()
      .optional(),
    refs: z.array(Ref).optional(),
    ack: z
      .object({
        status: z.string(),
        closed: z.boolean().nullable().optional(),
        note: z.string().optional(),
        metric_id: z.string().optional(),
        at_now: z.unknown().optional(),
        now: z.unknown().optional(),
      })
      .nullable()
      .optional(),
  })
  .passthrough();

const Turn = z
  .object({
    index: z.number(),
    phase: z.string(),
    ts: z.string(),
    tools: z.number().optional(),
    fails: z.number().optional(),
    retries: z.number().optional(),
    work_s: z.number().optional(),
    wait_s: z.number().optional(),
    wall_s: z.number().optional(),
    cost_usd: z.number().optional(),
    tokens_out: z.number().optional(),
    cache_write: z.number().optional(),
    prompt: z.string().optional(),
    nudge: z.boolean().optional(),
  })
  .passthrough();

const Summary = z
  .object({
    n_rows: z.number().optional(),
    n_turns: z.number().optional(),
    n_tools: z.number().optional(),
    work_s: z.number().optional(),
    wait_s: z.number().optional(),
    fail_s: z.number().optional(),
    fail_n: z.number().optional(),
    idle_s: z.number().optional(),
    cost_usd: z.number().optional(),
    cache_hit_pct: z.number().optional(),
    usage_turns: z.number().optional(),
    tools_per_turn: z.number().optional(),
    tokens_out: z.number().optional(),
    cache_write: z.number().optional(),
    cache_read: z.number().optional(),
    health: z
      .object({
        score: z.number(),
        grade: z.string(),
        fail_rate: z.number().optional(),
        waste_pct: z.number().optional(),
        redundant_reads: z.number().optional(),
      })
      .optional(),
    flow: z.object({ extra_roundtrips: z.number().optional() }).passthrough().optional(),
  })
  .passthrough();

export const MineSchema = z
  .object({
    ok: z.boolean(),
    scope: z.string(),
    error: z.string().optional(),
    session_id: z.string().optional(),
    n_rows: z.number().optional(),
    n_turns: z.number().optional(),
    summary: Summary.optional(),
    metrics: z.array(Metric).optional(),
    losses: z.array(Loss).optional(),
    findings: z.array(Finding).optional(),
    feedback: z.array(Finding).optional(),
    blocks: z.record(z.string(), Block).optional(),
    turns: z.array(Turn).optional(),
    directions: z.array(z.object({ id: z.string(), title: z.string() })).optional(),
    active: z.array(z.string()).nullable().optional(),
    window: z
      .object({
        from: z.string().optional(),
        to: z.string().optional(),
        instances: z.array(z.string()).optional(),
        truncated: z.boolean().optional(),
      })
      .passthrough()
      .optional(),
    series: z
      .object({ cache: z.object({ read: z.number(), uncached: z.number() }) })
      .passthrough()
      .optional(),
    loop: z
      .object({
        total: z.number(),
        closed: z.array(z.unknown()).optional(),
        open: z.array(z.unknown()).optional(),
        dismissed: z.array(z.unknown()).optional(),
      })
      .passthrough()
      .nullable()
      .optional(),
    baseline: z.object({ source: z.string().optional() }).passthrough().nullable().optional(),
  })
  .passthrough();

export type Mine = z.infer<typeof MineSchema>;
export type MineMetric = z.infer<typeof Metric>;
export type MineFinding = z.infer<typeof Finding>;
export type MineTurn = z.infer<typeof Turn>;
export type MineBlock = z.infer<typeof Block>;
export type MineTable = z.infer<typeof Table>;
export type MineRef = z.infer<typeof Ref>;
export type MineDirection = { id: string; title: string };

const BASE =
  typeof location !== "undefined" && location.pathname.startsWith("/trae") ? "/trae" : "";

export async function getMine(
  scope: string,
  dirs: string[],
  baseline: boolean,
  sessionId = "",
): Promise<Mine> {
  const params = new URLSearchParams({ scope, format: "full" });
  if (scope === "session" && sessionId) params.set("session_id", sessionId);
  if (dirs.length) params.set("dirs", dirs.join(","));
  if (baseline) params.set("baseline", "1");
  const res = await fetch(`${BASE}/api/mine?${params}`, {
    headers: { accept: "application/json" },
  });
  if (!res.ok) throw new Error(`/api/mine -> ${res.status}`);
  return MineSchema.parse(await res.json());
}

export async function ackFinding(payload: {
  scope: string;
  session_id: string;
  finding_id: string;
  status: string;
  metric: { id: string; now: unknown; target: unknown };
}): Promise<void> {
  const res = await fetch(`${BASE}/api/mine/ack`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`/api/mine/ack -> ${res.status}`);
}

export function useMine(scope: string, dirs: string[], baseline: boolean, sessionId = "") {
  return useQuery({
    queryKey: ["mine", scope, dirs.join(","), baseline, sessionId],
    queryFn: () => getMine(scope, dirs, baseline, sessionId),
    staleTime: 30_000,
  });
}
