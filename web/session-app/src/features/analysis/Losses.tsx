import { useState } from "react";
import type { Mine, MineFinding, MineRef } from "../../api/mine";
import { cn } from "../../lib/cn";
import {
  barPct,
  deltaText,
  deltaTone,
  lossParts,
  metricOf,
  mineSpan,
  mineUsd,
  pct,
  refHits,
  sevOf,
} from "./lib";
import { Pill, Section, SectionHead } from "./Section";

const abbrev = (s: unknown, n = 44): string => {
  const t = String(s || "");
  if (t.length <= n) return t;
  const head = Math.ceil((n - 1) / 2);
  return `${t.slice(0, head)}…${t.slice(t.length - (n - 1 - head))}`;
};

/** Dedup repeated refs (same failure six times → one chip ×6). */
function groupRefs(refs: MineRef[] | undefined) {
  const seen = new Map<string, { ref: MineRef; n: number }>();
  for (const r of refs || []) {
    if (r.turn === null || r.turn === undefined) continue;
    const key = `${r.turn}|${r.label}|${r.exit_code || ""}`;
    const hit = seen.get(key);
    if (hit) hit.n += 1;
    else seen.set(key, { ref: r, n: 1 });
  }
  return [...seen.values()];
}

const chipCls =
  "h-6 rounded-[6px] bg-black/[0.05] px-2 text-[12px] leading-6 text-role-system hover:bg-black/[0.09]";

function Refs({ refs, onTurn }: { refs: MineRef[] | undefined; onTurn: (n: number) => void }) {
  const grouped = groupRefs(refs);
  const noTurn = (refs || []).filter((r) => r.turn === null || r.turn === undefined).slice(0, 4);
  if (!grouped.length && !noTurn.length) return null;
  const shown = grouped.slice(0, 3);
  const more = grouped.length - shown.length;
  return (
    <div className="flex min-w-0 flex-1 flex-wrap gap-1.5">
      {shown.map(({ ref: r, n }) => (
        <button
          key={`${r.turn}-${r.label}-${r.exit_code}`}
          type="button"
          onClick={() => onTurn(Number(r.turn))}
          title={`${r.label || ""} ${r.event_id || ""}`}
          className={chipCls}
        >
          #{Number(r.turn)} {abbrev(r.label, 26)}
          {r.exit_code ? ` · exit ${r.exit_code}` : ""}
          {n > 1 ? ` ×${n}` : ""}
        </button>
      ))}
      {more > 0 && (
        <button
          type="button"
          onClick={() => onTurn(Number(grouped[3]?.ref.turn))}
          className={chipCls}
        >
          +{more}
        </button>
      )}
      {noTurn.map((r) => (
        <span key={r.label} className={chipCls}>
          {abbrev(r.label)}
        </span>
      ))}
    </div>
  );
}

/**
 * Where a finding's evidence sits in the run: one tick per turn (same order as
 * ③), darker = more refs. Hover reads the turn, click opens it in ③.
 */
function EvidenceStrip({
  f,
  data,
  onTurn,
}: {
  f: MineFinding;
  data: Mine;
  onTurn: (n: number) => void;
}) {
  const turns = data.turns || [];
  const hits = refHits(f.refs);
  const [hover, setHover] = useState<number | null>(null);
  if (!turns.length || !hits.size) return null;
  const max = Math.max(1, ...hits.values());
  const t = hover != null ? turns[hover] : null;
  return (
    <div className="mt-3">
      <div className="mb-1 flex h-4 items-center gap-2 text-[11.5px] tabular-nums text-role-system">
        <span>证据分布</span>
        <span className="truncate text-ink">
          {t
            ? `#${t.index} · ${hits.get(Number(t.index)) || 0} 条 · ${String(t.prompt || "").slice(0, 40)}`
            : `${hits.size}/${turns.length} 回合`}
        </span>
      </div>
      <div className="flex h-4 gap-[2px]" onPointerLeave={() => setHover(null)}>
        {turns.map((tt, i) => {
          const n = hits.get(Number(tt.index)) || 0;
          return (
            <button
              key={tt.index}
              type="button"
              aria-label={`回合 ${tt.index}${n ? `，${n} 条证据` : ""}`}
              disabled={!n}
              onPointerEnter={() => setHover(i)}
              onFocus={() => setHover(i)}
              onClick={() => onTurn(Number(tt.index))}
              className={cn("block h-full min-w-0 flex-1", n ? "cursor-pointer" : "cursor-default")}
              style={{
                background: n ? `rgba(194,65,12,${0.3 + (0.7 * n) / max})` : "rgba(60,60,67,0.08)",
                outline: hover === i ? "1.5px solid #1d1d1f" : undefined,
              }}
            />
          );
        })}
      </div>
    </div>
  );
}

function Ack({
  f,
  onAck,
}: {
  f: MineFinding;
  onAck: (f: MineFinding, status: string, btn?: HTMLElement) => void;
}) {
  const a = f.ack;
  const m = f.metric;
  const buttons = (
    <span className="flex items-center gap-2">
      <button
        type="button"
        onClick={(e) => onAck(f, "applied", e.currentTarget)}
        className="h-7 rounded-full border border-black/12 px-3 text-[12px] font-medium text-ink hover:border-role-assistant hover:text-role-assistant"
      >
        标记已应用
      </button>
      <button
        type="button"
        onClick={(e) => onAck(f, "dismissed", e.currentTarget)}
        className="h-7 rounded-full border border-black/12 px-3 text-[12px] font-medium text-role-system hover:border-role-assistant hover:text-role-assistant"
      >
        忽略
      </button>
    </span>
  );
  if (!a) return buttons;
  const closed = a.closed === true ? "good" : a.closed === false ? "open" : "note";
  const label =
    a.status === "dismissed"
      ? "已忽略"
      : a.closed === true
        ? "已闭环"
        : a.closed === false
          ? "未改善"
          : "无目标";
  const cls =
    closed === "good"
      ? "bg-mine-good/12 text-mine-good"
      : closed === "open"
        ? "bg-mine-loss/12 text-mine-loss"
        : "bg-black/[0.06] text-role-system";
  return (
    <div className="flex flex-wrap items-center justify-end gap-2 text-[12px] text-role-system">
      <span className={`rounded-full px-2 py-0.5 font-semibold ${cls}`}>{label}</span>
      <span className="tabular-nums">
        {m?.id || a.metric_id || ""} {String(a.at_now ?? "-")} → {String(a.now ?? "-")}
        {m?.target !== null && m?.target !== undefined
          ? `（目标 ${String(m?.target)}${m?.unit || ""}）`
          : ""}
        {a.note ? ` · ${a.note}` : ""}
      </span>
      {buttons}
    </div>
  );
}

function LossCard({
  f,
  i,
  data,
  onTurn,
  onAck,
}: {
  f: MineFinding;
  i: number;
  data: Mine;
  onTurn: (n: number) => void;
  onAck: (f: MineFinding, status: string, btn?: HTMLElement) => void;
}) {
  const sev = sevOf(f.sev);
  const imp = f.impact || { s: 0, usd: 0, kind: "measured" };
  const m = f.metric;
  const mm = m?.id ? metricOf(data, m.id) : null;
  const reached = !!(
    m &&
    m.target !== null &&
    m.target !== undefined &&
    mm &&
    mm.dir !== "up" &&
    Number(m.now) <= Number(m.target)
  );
  const dt = mm ? deltaText(mm) : "";
  const dTone = mm ? deltaTone(mm) : "";
  const lp = lossParts(data);
  const share = imp.s > 0 && lp.totalS > 0 && f.id !== "idle" ? pct(imp.s, lp.totalS) : null;
  const metricRow = m && (
    <div
      className={cn(
        "flex flex-wrap items-center gap-x-3 gap-y-1 rounded-[8px] px-2.5 py-1.5 text-[12.5px]",
        reached ? "bg-mine-good/8" : "bg-black/[0.03]",
      )}
    >
      <span className="font-medium text-role-system">{mm?.label || m.id}</span>
      <span className="font-semibold tabular-nums text-mine-loss">
        {String(m.now ?? "—")}
        {m.unit || ""}
      </span>
      {m.target !== null && m.target !== undefined && (
        <>
          <span className="text-role-system">
            → 目标 {String(m.target)}
            {m.unit || ""}
          </span>
          <span className="relative h-1.5 w-16 overflow-hidden bg-black/[0.07]">
            <i
              className="absolute inset-y-0 left-0 bg-mine-loss"
              style={{ width: `${mm ? barPct(mm) : 0}%` }}
            />
          </span>
        </>
      )}
      {dt && (
        <span
          className={cn(
            "tabular-nums",
            dTone === "up"
              ? "text-mine-loss"
              : dTone === "down"
                ? "text-mine-good"
                : "text-role-system",
          )}
        >
          较基线 {dt}
        </span>
      )}
    </div>
  );
  return (
    <article
      id={`loss-${f.id || i}`}
      className="scroll-mt-4 rounded-[14px] border border-black/[0.06] bg-white px-4 py-3"
    >
      <div className="flex items-center gap-2.5">
        <span className="w-4 shrink-0 text-[13px] font-semibold tabular-nums text-role-system">
          {i + 1}
        </span>
        <h4
          className="min-w-0 flex-1 truncate text-[15px] font-semibold tracking-[-0.01em] text-ink"
          title={f.title}
        >
          {f.title}
        </h4>
        <Pill tone={sev.badge}>{sev.label}</Pill>
        <span className="text-[11.5px] text-role-system">
          {imp.kind === "estimated" ? "估算" : "实测"}
        </span>
        <b className="w-[64px] text-right text-[15px] font-semibold tabular-nums text-mine-loss">
          {mineSpan(imp.s)}
        </b>
        <span className="w-[56px] text-right text-[12px] tabular-nums text-mine-money">
          {Number(imp.usd) > 0 ? mineUsd(imp.usd) : ""}
        </span>
      </div>
      {share != null && (
        <div className="ml-[26px] mt-1.5 flex items-center gap-2 text-[11.5px] tabular-nums text-role-system">
          <span className="relative h-1 flex-1 bg-black/[0.05]">
            <i className="absolute inset-y-0 left-0 bg-mine-loss" style={{ width: `${share}%` }} />
          </span>
          占可归因损耗 {share.toFixed(0)}%
        </div>
      )}

      <div className="ml-[26px] mt-2 grid grid-cols-1 gap-x-5 gap-y-2 @2xl:grid-cols-[minmax(0,1.618fr)_minmax(0,1fr)]">
        <div className="min-w-0">
          {f.text && <p className="mb-1.5 text-[13px] leading-snug text-ink">{f.text}</p>}
          <dl className="grid grid-cols-[36px_minmax(0,1fr)] gap-x-2 gap-y-1 text-[13px] leading-snug">
            {f.cause && (
              <>
                <dt className="font-medium text-role-system">原因</dt>
                <dd className="text-ink">{f.cause}</dd>
              </>
            )}
            {f.action && (
              <>
                <dt className="font-medium text-role-assistant">动作</dt>
                <dd className="text-role-assistant">{f.action}</dd>
              </>
            )}
            {f.gate && (
              <>
                <dt className="font-medium text-role-system">闸门</dt>
                <dd className="text-ink">{String(f.gate).replace(/^-\s*/, "")}</dd>
              </>
            )}
          </dl>
        </div>
        <div className="min-w-0">
          {metricRow}
          <EvidenceStrip f={f} data={data} onTurn={onTurn} />
        </div>
      </div>
      <div className="ml-[26px] mt-2.5 flex flex-wrap items-center gap-2">
        <Refs refs={f.refs} onTurn={onTurn} />
        <span className="ml-auto">
          <Ack f={f} onAck={onAck} />
        </span>
      </div>
    </article>
  );
}

/** ② 发现: one card per finding, ordered by impact. Composition lives in ①. */
export function Losses({
  data,
  onTurn,
  onAck,
}: {
  data: Mine;
  onTurn: (n: number) => void;
  onAck: (f: MineFinding, status: string, btn?: HTMLElement) => void;
}) {
  const list = data.findings || [];
  const hasEst = list.some((f) => f.impact?.kind === "estimated");
  if (!list.length) {
    return (
      <Section id="mineLosses">
        <SectionHead title="发现" count={0} />
        <p className="rounded-[14px] border border-black/[0.06] bg-white p-4 text-[13px] text-role-system">
          {data.n_rows ? "没有信号形成结论" : "还没有足够事件"}
        </p>
      </Section>
    );
  }

  return (
    <Section id="mineLosses">
      <SectionHead
        title="发现"
        count={list.length}
        hint={hasEst ? "按影响排序 · 含估算项" : "按影响排序"}
      />
      <div className="flex flex-col gap-3">
        {list.map((f, i) => (
          <LossCard key={f.id || i} f={f} i={i} data={data} onTurn={onTurn} onAck={onAck} />
        ))}
      </div>
    </Section>
  );
}
