import { CHART_PALETTE, colorAt, fmtValue, PHASE_COLORS, SEV_COLORS } from "@charts";
import { parseHookTs } from "@render";
import type { Mine } from "../../api/mine";

/**
 * Analysis presentation helpers. Taste (docs/design-taste.md 「分析」):
 * colour is an information channel that always carries its number; the
 * structure is ① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本.
 */

export { CHART_PALETTE, colorAt, fmtValue, PHASE_COLORS, SEV_COLORS };

export const MINE_PHASES = ["implement", "review", "debug", "ship", "taste"] as const;

export const PHASE_LABEL: Record<string, string> = {
  implement: "实现",
  review: "评审",
  debug: "排查",
  ship: "提交",
  taste: "规范",
  other: "其他",
};

/** Literal Tailwind classes (scanned at build time — never build names dynamically). */
export const PHASE_BADGE: Record<string, string> = {
  implement: "bg-phase-implement/12 text-phase-implement",
  review: "bg-phase-review/12 text-phase-review",
  debug: "bg-phase-debug/12 text-phase-debug",
  ship: "bg-phase-ship/12 text-phase-ship",
  taste: "bg-phase-taste/12 text-phase-taste",
  other: "bg-phase-other/12 text-phase-other",
};

export type SevStyle = { label: string; badge: string; edge: string; card: string; color: string };

export const SEV: Record<string, SevStyle> = {
  high: {
    label: "需处理",
    badge: "bg-sev-high/12 text-sev-high",
    edge: "border-l-sev-high",
    card: "border-l-sev-high bg-gradient-to-b from-sev-high/8 to-white",
    color: SEV_COLORS.high,
  },
  med: {
    label: "注意",
    badge: "bg-sev-med/12 text-sev-med",
    edge: "border-l-sev-med",
    card: "border-l-sev-med bg-gradient-to-b from-sev-med/8 to-white",
    color: SEV_COLORS.med,
  },
  note: {
    label: "观察",
    badge: "bg-sev-note/12 text-sev-note",
    edge: "border-l-sev-note",
    card: "border-l-sev-note bg-white",
    color: SEV_COLORS.note,
  },
  good: {
    label: "良好",
    badge: "bg-sev-good/12 text-sev-good",
    edge: "border-l-sev-good",
    card: "border-l-sev-good bg-gradient-to-b from-sev-good/8 to-white",
    color: SEV_COLORS.good,
  },
};

/** Numeric table columns get an in-cell magnitude bar. */
export const MINE_NUM_COLS = new Set([
  "n",
  "writes",
  "reads",
  "sec",
  "share",
  "work",
  "wait",
  "tools",
  "fail",
  "rate",
  "tokens",
  "loads",
  "avg_tokens",
  "total_tokens",
  "usd",
  "inp",
  "cr",
  "out",
  "hit",
  "e2e",
]);

export const sevOf = (sev: string): SevStyle => SEV[sev] || SEV.note;
export const phaseColor = (phase: string, i: number) => PHASE_COLORS[phase] || colorAt(i);
export const phaseLabel = (phase: string) => PHASE_LABEL[phase] || "其他";
export const isKnownPhase = (phase: string) => (MINE_PHASES as readonly string[]).includes(phase);

export const CHART_KINDS = ["stack", "donut", "bars", "columns", "line"] as const;
export type ChartKind = (typeof CHART_KINDS)[number];

/**
 * Shape follows the data, not the backend's declared kind. A bar chart with few
 * parts, or one part dominating, is really a part-to-whole question — the bars
 * sit as slivers in a sea of empty space. Use a ring instead (taste: 「分析」图表
 * 选型 + 「色彩条直角」).
 */
export function pickKind(declared: string, items: { value: number }[]): ChartKind {
  const kind = (CHART_KINDS as readonly string[]).includes(declared)
    ? (declared as ChartKind)
    : "bars";
  if (kind === "line" && items.length < 3) return "bars";
  if (kind === "bars") {
    const positive = items.filter((i) => Number(i.value) > 0);
    if (!positive.length) return "bars";
    const total = positive.reduce((a, i) => a + Number(i.value), 0);
    const max = Math.max(...positive.map((i) => Number(i.value)));
    if (positive.length <= 4 || (total > 0 && max / total >= 0.7)) return "donut";
  }
  return kind;
}

export const mineSpan = (v: unknown): string => {
  const n = Number(v) || 0;
  if (n >= 3600) return `${(n / 3600).toFixed(1)}h`;
  if (n >= 60) return `${Math.round(n)}s`;
  return `${Math.round(n * 10) / 10}s`;
};

export const mineUsd = (v: unknown): string => {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  return n >= 0.1 ? `$${n.toFixed(3)}` : `$${n.toFixed(4)}`;
};

export const pct = (part: number, whole: number) => (whole > 0 ? (100 * part) / whole : 0);

export const metricOf = (data: Mine | null | undefined, id: string) =>
  (data?.metrics || []).find((m) => m.id === id) || null;

export const deltaText = (m: { delta?: number | null } | null | undefined): string => {
  if (!m || m.delta === null || m.delta === undefined) return "";
  const d = Number(m.delta);
  if (!Number.isFinite(d) || d === 0) return "Δ0";
  return `Δ${d > 0 ? "+" : "-"}${Math.abs(d) >= 100 ? Math.round(Math.abs(d)) : Math.round(Math.abs(d) * 100) / 100}`;
};

/** "worse" depends on the metric's desired direction. */
export const deltaTone = (
  m: { delta?: number | null; dir?: string } | null | undefined,
): "up" | "down" | "" => {
  if (!m || m.delta === null || m.delta === undefined) return "";
  const d = Number(m.delta);
  if (!Number.isFinite(d) || d === 0) return "";
  return (m.dir === "up" ? d < 0 : d > 0) ? "up" : "down";
};

export const barPct = (
  m: { value?: unknown; target?: number | null } | null | undefined,
): number => {
  if (!m || m.target === null || m.target === undefined) return 0;
  const now = Number(m.value) || 0;
  const tgt = Number(m.target) || 0;
  if (tgt <= 0) return now > 0 ? 100 : 0;
  return Math.max(4, Math.min(100, Math.round((100 * now) / tgt)));
};

/** AGENTS 草稿: the copy payload behind 「复制 AGENTS 草稿」. */
export const mineDraftMarkdown = (data: Mine | null): string => {
  const found = data?.findings || data?.feedback || [];
  const ruled = found.filter((f) => f.draft);
  const win = data?.window || {};
  return [
    `# 从会话分析得到的约束（${data?.scope || "session"} · ${win.from || ""} → ${win.to || ""}）`,
    "",
    ...(ruled.length
      ? ruled.map((f, i) => {
          const imp = f.impact || { s: 0, usd: 0, kind: "measured" };
          const cost = [imp.s ? `${imp.s}s` : "", imp.usd ? `$${imp.usd}` : ""]
            .filter(Boolean)
            .join(" / ");
          return [
            `## ${i + 1}. ${f.title}${cost ? `（${cost}，${imp.kind === "estimated" ? "估算" : "实测"}）` : ""}`,
            f.draft,
            "",
          ].join("\n");
        })
      : found.map((f) => `- ${f.text || f.title}`)),
    "",
    "<!-- 复测：同一窗口重跑会话分析，指标应向 target 移动 -->",
    "",
  ].join("\n");
};

// ---------------------------------------------------------------------------
// Sheet readings (pure; tested in lib.test.ts). The sheet answers, in order:
// how bad was it → where did the loss go → which turn → the ledger behind it.
// ---------------------------------------------------------------------------

const pad2 = (n: number) => String(n).padStart(2, "0");
const dayOf = (d: Date) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
const hmOf = (d: Date) => `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;

/** Local HH:mm of a hook timestamp (naive UTC in the store). */
export const localHm = (ts: unknown): string => {
  const d = parseHookTs(ts);
  return d ? hmOf(d) : "";
};

/** Analysis window in local time, minutes resolution. Never raw UTC microseconds. */
export function windowText(w: { from?: unknown; to?: unknown } | null | undefined): string {
  const a = parseHookTs(w?.from);
  const b = parseHookTs(w?.to);
  if (!a || !b) return "";
  if (dayOf(a) === dayOf(b)) return `${dayOf(a)} ${hmOf(a)}–${hmOf(b)}`;
  return `${dayOf(a).slice(5)} ${hmOf(a)} – ${dayOf(b).slice(5)} ${hmOf(b)}`;
}

export type LossPart = {
  id: string;
  label: string;
  s: number;
  usd: number;
  kind: string;
  color: string;
};

/** One hue for loss, stepped by rank: the legend names the parts, colour only says "loss". */
const LOSS_RAMP = [1, 0.72, 0.52, 0.36, 0.24];

/**
 * Losses that share one axis. `idle` is a wall-clock gap between events, not
 * tool time (docs/session-analysis.md L1g), so it never joins the composition
 * or the shared bar scale — in a 7-day window it would be 99% of the bar.
 */
export function lossParts(data: Mine | null | undefined): {
  parts: LossPart[];
  idle: LossPart | null;
  totalS: number;
  totalUsd: number;
} {
  const all = (data?.losses || []).map((l) => ({
    id: String(l.id),
    label: String(l.label || l.id),
    s: Number(l.s) || 0,
    usd: Number(l.usd) || 0,
    kind: String(l.kind || "measured"),
    color: SEV_COLORS.high,
  }));
  const idleRaw = all.find((l) => l.id === "idle" && l.s > 0) || null;
  const parts = all
    .filter((l) => l.id !== "idle" && l.s > 0)
    .sort((a, b) => b.s - a.s)
    .map((l, i) => ({
      ...l,
      color: `rgba(194,65,12,${LOSS_RAMP[Math.min(i, LOSS_RAMP.length - 1)]})`,
    }));
  return {
    parts,
    idle: idleRaw ? { ...idleRaw, color: "rgba(60,60,67,0.30)" } : null,
    totalS: parts.reduce((a, l) => a + l.s, 0),
    totalUsd: all.reduce((a, l) => a + l.usd, 0),
  };
}

export type Tone = "good" | "ok" | "warn" | "bad";
export const scoreTone = (score: number): Tone =>
  score >= 85 ? "good" : score >= 70 ? "ok" : score >= 50 ? "warn" : "bad";

/** The status card in one sentence + one line of facts. */
export function verdictHeadline(data: Mine): {
  score: number | null;
  grade: string;
  tone: Tone;
  title: string;
  detail: string;
  idle: string;
} {
  const s = data.summary || {};
  const h = s.health;
  const score = h ? Number(h.score) || 0 : null;
  const lp = lossParts(data);
  const top = lp.parts[0];
  const title =
    lp.totalS > 0
      ? `可归因损耗 ${mineSpan(lp.totalS)}${lp.totalUsd > 0 ? ` · ${mineUsd(lp.totalUsd)}` : ""}`
      : "没有可归因的损耗";
  const facts = [
    top ? `最大一项 ${top.label} ${mineSpan(top.s)}` : "",
    `${Number(s.n_turns) || 0} 回合`,
    `${Number(s.n_tools) || 0} 工具`,
  ].filter(Boolean);
  return {
    score,
    grade: h?.grade || "",
    tone: scoreTone(score ?? 0),
    title,
    detail: facts.join(" · "),
    idle: lp.idle
      ? `另有长空档 ${mineSpan(lp.idle.s)}（事件之间的墙钟间隔，不与工具耗时同轴）`
      : "",
  };
}

/** KPI grid: data-driven from `metrics` so each number carries its baseline Δ. */
export const KPI_IDS = [
  "work_s",
  "wait_s",
  "fail_n",
  "extra_trips",
  "tools_per_turn",
  "reread_extra",
  "locate_s",
  "waste_pct",
] as const;

export const metricText = (m: { value?: unknown; unit?: string } | null | undefined): string => {
  if (!m || m.value === null || m.value === undefined || m.value === "") return "—";
  if (m.unit === "s") return mineSpan(m.value);
  const n = Number(m.value);
  // Small ratios (2.87 次/文件) must keep their decimals; fmtValue rounds to 0.
  const digits = Number.isFinite(n) && !Number.isInteger(n) && Math.abs(n) < 10 ? 2 : 1;
  return fmtValue(m.value, m.unit === "次" ? "" : m.unit || "", digits);
};

export type TurnBar = {
  index: number;
  pct: number;
  fail: boolean;
  color: string;
  phase: string;
};

/** What the strip's height can encode. Colour stays phase; red cap stays failure. */
export const STRIP_METRICS = [
  { id: "wall_s", label: "墙钟" },
  { id: "tools", label: "工具" },
  { id: "cost_usd", label: "费用" },
  { id: "tokens_out", label: "输出" },
] as const;
export type StripMetric = (typeof STRIP_METRICS)[number]["id"];

export const stripValueText = (key: StripMetric, v: unknown): string => {
  if (key === "wall_s") return mineSpan(v);
  if (key === "cost_usd") return mineUsd(v);
  if (key === "tokens_out") return fmtValue(v, "tok");
  return `${Number(v) || 0} 工具`;
};

/**
 * Turn strip marks: height = the chosen metric on one scale, colour = phase,
 * fail flagged. A zero is drawn as zero (baseline only), never as a stub.
 */
export function turnBars(turns: MineTurnLike[], key: StripMetric = "wall_s"): TurnBar[] {
  const val = (t: MineTurnLike) => Number((t as Record<string, unknown>)[key]) || 0;
  const max = Math.max(0, ...turns.map(val));
  return turns.map((t) => {
    const v = val(t);
    return {
      index: Number(t.index),
      pct: v > 0 && max > 0 ? Math.max(4, Math.round((100 * v) / max)) : 0,
      fail: Number(t.fails) > 0,
      color: phaseColor(String(t.phase), 0),
      phase: String(t.phase),
    };
  });
}

/** Where the local day changes between consecutive turns (7-day scope). */
export function dayBreaks(turns: { ts: string }[]): { at: number; label: string }[] {
  const out: { at: number; label: string }[] = [];
  let prev = "";
  turns.forEach((t, i) => {
    const d = parseHookTs(t.ts);
    const day = d ? dayOf(d) : "";
    if (i > 0 && day && prev && day !== prev) out.push({ at: i, label: day.slice(5) });
    if (day) prev = day;
  });
  return out;
}

/** Evidence spread of a finding: how many refs point at each turn. */
export function refHits(refs: { turn?: number | null }[] | undefined): Map<number, number> {
  const m = new Map<number, number>();
  for (const r of refs || []) {
    if (r.turn === null || r.turn === undefined) continue;
    const n = Number(r.turn);
    if (!Number.isFinite(n)) continue;
    m.set(n, (m.get(n) || 0) + 1);
  }
  return m;
}

export type SortState = { key: string; dir: "asc" | "desc" } | null;

/** Header click cycles desc → asc → original order. Numbers sort as numbers. */
export const nextSort = (cur: SortState, key: string): SortState =>
  !cur || cur.key !== key ? { key, dir: "desc" } : cur.dir === "desc" ? { key, dir: "asc" } : null;

export function sortRows<T extends Record<string, unknown>>(
  rows: T[],
  sort: SortState,
  numeric: (key: string) => boolean = (k) => MINE_NUM_COLS.has(k),
): T[] {
  if (!sort) return rows;
  const { key, dir } = sort;
  const sign = dir === "asc" ? 1 : -1;
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => {
      const x = a.r[key];
      const y = b.r[key];
      const c = numeric(key)
        ? (Number(x) || 0) - (Number(y) || 0)
        : String(x ?? "").localeCompare(String(y ?? ""), "zh");
      return c ? sign * c : a.i - b.i;
    })
    .map((e) => e.r);
}

/** Ledger filter: a row stays when any text cell contains the query. */
export function filterRows<T extends Record<string, unknown>>(
  rows: T[],
  cols: { id: string }[],
  query: string,
): T[] {
  const q = query.trim().toLowerCase();
  if (!q) return rows;
  return rows.filter((r) =>
    cols.some((c) =>
      String(r[c.id] ?? "")
        .toLowerCase()
        .includes(q),
    ),
  );
}

/** Sum rows (合计) are not parts: a composition that includes them double-counts. */
export const isTotalLabel = (s: unknown) => /合计|总计/.test(String(s ?? ""));

/** `metric | value` tables read as a tile grid, not as a two-column list. */
export const isKvTable = (cols: { id: string }[] | undefined) =>
  (cols || []).length === 2 && cols?.[1]?.id === "value";

/** A ledger table that lists turns (ts + prompt) repeats ③ 回合. */
export const isTurnTable = (cols: { id: string }[] | undefined) => {
  const ids = new Set((cols || []).map((c) => c.id));
  return ids.has("ts") && ids.has("prompt");
};

/** Prompt clues (路径 / 仓库) from the ledger, keyed by turn ts, so ③ can show them inline. */
export function turnClues(
  blocks:
    | Record<string, { tables?: { cols?: { id: string }[]; rows?: Record<string, unknown>[] }[] }>
    | undefined,
): Map<string, { path: boolean; repo: boolean }> {
  const out = new Map<string, { path: boolean; repo: boolean }>();
  for (const b of Object.values(blocks || {})) {
    for (const t of b.tables || []) {
      const ids = new Set((t.cols || []).map((c) => c.id));
      if (!(ids.has("ts") && ids.has("path") && ids.has("repo"))) continue;
      for (const r of t.rows || []) {
        out.set(String(r.ts), { path: r.path === "有", repo: r.repo === "有" });
      }
    }
  }
  return out;
}

/** Long paths keep their file name: the directory is what truncates. */
export function splitPath(s: unknown): { dir: string; base: string } {
  const t = String(s ?? "");
  const i = t.lastIndexOf("/");
  if (i <= 0 || i === t.length - 1 || t.includes(" ")) return { dir: "", base: t };
  return { dir: t.slice(0, i + 1), base: t.slice(i + 1) };
}

type MineTurnLike = {
  index: number;
  phase: string;
  ts: string;
  wall_s?: number;
  fails?: number;
  tools?: number;
  cost_usd?: number;
};

/** Phase legend under the strip: where the wall clock went, by phase. */
export function phaseTotals(turns: MineTurnLike[]) {
  const by = new Map<string, number>();
  for (const t of turns) by.set(t.phase, (by.get(t.phase) || 0) + (Number(t.wall_s) || 0));
  return [...by.entries()]
    .filter(([, s]) => s > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([phase, s]) => ({ phase, label: phaseLabel(phase), s, color: phaseColor(phase, 0) }));
}

export function turnReadout(t: MineTurnLike): string {
  return [
    `#${t.index}`,
    phaseLabel(t.phase),
    localHm(t.ts),
    mineSpan(t.wall_s),
    `${Number(t.tools) || 0} 工具`,
    Number(t.fails) ? `${Number(t.fails)} 失败` : "",
    Number(t.cost_usd) ? mineUsd(t.cost_usd) : "",
  ]
    .filter(Boolean)
    .join(" · ");
}

/**
 * Ledger chart policy. The table already draws an in-cell magnitude bar for each
 * numeric column, so a `bars` chart of the same column only repeats it; a ring
 * with a single part is a filled circle that says "100%". Neither is drawn.
 */
export function ledgerChart(declared: string, items: { value: number }[]): ChartKind | null {
  const picked = pickKind(declared, items);
  if (picked === "bars") return null;
  if (picked === "donut" && items.filter((i) => Number(i.value) > 0).length < 2) return null;
  return picked;
}

/** Per-day cost from the ledger's 「每天成本曲线」 table (agent.metrics). */
export function dailyCost(
  data: Mine | null | undefined,
): { day: string; usd: number; n: number }[] {
  for (const b of Object.values(data?.blocks || {})) {
    for (const t of b.tables || []) {
      const ids = new Set((t.cols || []).map((c) => c.id));
      if (!(ids.has("day") && ids.has("usd"))) continue;
      return (t.rows || []).map((r) => ({
        day: String(r.day ?? ""),
        usd: Number(r.usd) || 0,
        n: Number(r.n) || 0,
      }));
    }
  }
  return [];
}
