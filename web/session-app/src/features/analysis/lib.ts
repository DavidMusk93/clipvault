import { CHART_PALETTE, colorAt, fmtValue, PHASE_COLORS, SEV_COLORS } from "@charts";
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
