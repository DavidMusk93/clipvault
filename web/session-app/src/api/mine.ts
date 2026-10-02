import { useQuery } from "@tanstack/react-query";
import { z } from "zod";

/** `/api/mine` (Session Analysis v2) contract, permissively parsed. */

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

const Block = z.object({
  title: z.string(),
  axis: z.string(),
  note: z.string().optional(),
  table: Table.optional(),
  tables: z.array(Table).optional(),
});

const Metric = z.object({
  id: z.string(),
  label: z.string(),
  unit: z.string(),
  dir: z.string(),
  target: z.number().nullable().optional(),
  value: z.union([z.number(), z.string()]).nullable(),
  baseline: z.union([z.number(), z.string()]).nullable().optional(),
  delta: z.number().nullable().optional(),
  note: z.string().optional(),
});

const Loss = z.object({
  id: z.string(),
  label: z.string(),
  s: z.number(),
  usd: z.number(),
  kind: z.string(),
  how: z.string().optional(),
});

const Finding = z.object({
  id: z.string(),
  sev: z.string(),
  axis: z.string(),
  title: z.string(),
  text: z.string(),
  cause: z.string().optional(),
  action: z.string().optional(),
  gate: z.string().optional(),
  impact: z.object({ s: z.number(), usd: z.number(), kind: z.string() }),
  metric: z
    .object({
      id: z.string(),
      now: z.unknown(),
      target: z.unknown(),
      unit: z.string().optional(),
      dir: z.string().optional(),
    })
    .nullable()
    .optional(),
  ack: z
    .object({
      status: z.string(),
      closed: z.boolean().nullable().optional(),
      note: z.string().optional(),
    })
    .nullable()
    .optional(),
});

const Summary = z
  .object({
    n_rows: z.number().optional(),
    n_turns: z.number().optional(),
    n_tools: z.number().optional(),
    cost_usd: z.number().optional(),
    cache_hit_pct: z.number().optional(),
    usage_turns: z.number().optional(),
    health: z
      .object({
        score: z.number(),
        grade: z.string(),
        fail_rate: z.number(),
        waste_pct: z.number(),
        redundant_reads: z.number(),
      })
      .optional(),
  })
  .passthrough();

export const MineSchema = z
  .object({
    ok: z.boolean(),
    scope: z.string(),
    n_rows: z.number().optional(),
    n_turns: z.number().optional(),
    summary: Summary.optional(),
    metrics: z.array(Metric).optional(),
    losses: z.array(Loss).optional(),
    findings: z.array(Finding).optional(),
    blocks: z.record(z.string(), Block).optional(),
    loop: z.unknown().optional(),
    baseline: z.unknown().optional(),
  })
  .passthrough();

export type Mine = z.infer<typeof MineSchema>;
export type MineMetric = z.infer<typeof Metric>;
export type MineLoss = z.infer<typeof Loss>;
export type MineFinding = z.infer<typeof Finding>;
export type MineBlock = z.infer<typeof Block>;
export type MineTable = z.infer<typeof Table>;

const BASE =
  typeof location !== "undefined" && location.pathname.startsWith("/trae") ? "/trae" : "";

async function getMine(scope: string, dirs: string[], baseline: boolean): Promise<Mine> {
  const params = new URLSearchParams({ scope, format: "full" });
  if (dirs.length) params.set("dirs", dirs.join(","));
  if (baseline) params.set("baseline", "1");
  const res = await fetch(`${BASE}/api/mine?${params}`, {
    headers: { accept: "application/json" },
  });
  if (!res.ok) throw new Error(`/api/mine -> ${res.status}`);
  return MineSchema.parse(await res.json());
}

export function useMine(scope: string, dirs: string[], baseline: boolean) {
  return useQuery({
    queryKey: ["mine", scope, dirs.join(","), baseline],
    queryFn: () => getMine(scope, dirs, baseline),
    staleTime: 30_000,
  });
}
