import type { Mine, MineFinding, MineRef } from "../../api/mine";
import { barPct, deltaText, deltaTone, metricOf, mineSpan, mineUsd, sevOf } from "./lib";
import { MineChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

const abbrev = (s: unknown, n = 46): string => {
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

function Refs({ refs, onTurn }: { refs: MineRef[] | undefined; onTurn: (n: number) => void }) {
  const grouped = groupRefs(refs);
  const noTurn = (refs || []).filter((r) => r.turn === null || r.turn === undefined).slice(0, 4);
  if (!grouped.length && !noTurn.length) return null;
  const shown = grouped.slice(0, 4);
  const more = grouped.length - shown.length;
  return (
    <div className="mt-1.5 flex flex-wrap gap-1">
      {shown.map(({ ref: r, n }) => (
        <button
          key={`${r.turn}-${r.label}-${r.exit_code}`}
          type="button"
          onClick={() => onTurn(Number(r.turn))}
          title={`${r.label || ""} ${r.event_id || ""}`}
          className="rounded-md bg-black/[0.04] px-1.5 py-0.5 text-[10.5px] text-role-system hover:bg-black/[0.08]"
        >
          #{Number(r.turn)} {abbrev(r.label)}
          {r.exit_code ? ` · exit ${r.exit_code}` : ""}
          {n > 1 ? ` ×${n}` : ""}
        </button>
      ))}
      {more > 0 && (
        <button
          type="button"
          onClick={() => onTurn(Number(grouped[4]?.ref.turn))}
          className="rounded-md bg-black/[0.04] px-1.5 py-0.5 text-[10.5px] text-role-system hover:bg-black/[0.08]"
        >
          +{more} 更多（点回合看明细）
        </button>
      )}
      {noTurn.map((r) => (
        <span
          key={r.label}
          className="rounded-md bg-black/[0.04] px-1.5 py-0.5 text-[10.5px] text-role-system"
        >
          {abbrev(r.label)}
        </span>
      ))}
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
    <span className="flex items-center gap-1">
      <button
        type="button"
        onClick={(e) => onAck(f, "applied", e.currentTarget)}
        className="rounded-md border border-black/10 px-1.5 py-0.5 text-[10.5px] text-role-system hover:border-role-assistant hover:text-role-assistant"
      >
        标记已应用
      </button>
      <button
        type="button"
        onClick={(e) => onAck(f, "dismissed", e.currentTarget)}
        className="rounded-md border border-black/10 px-1.5 py-0.5 text-[10.5px] text-role-system hover:border-role-assistant hover:text-role-assistant"
      >
        忽略
      </button>
    </span>
  );
  if (!a) return <div className="mt-1.5 flex justify-end">{buttons}</div>;
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
    <div className="mt-1.5 flex flex-wrap items-center justify-end gap-1.5 text-[10.5px] text-role-system">
      <span className={`rounded-full px-1.5 py-0.5 font-semibold ${cls}`}>{label}</span>
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
  return (
    <article
      id={`loss-${f.id || i}`}
      className={`scroll-mt-11 rounded-xl border border-black/5 border-l-2 px-3 py-2.5 ${sev.card}`}
    >
      <div className="mb-1.5 flex items-center gap-2">
        <span className="text-[11px] font-semibold text-role-system tabular-nums">{i + 1}</span>
        <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-semibold ${sev.badge}`}>
          {sev.label}
        </span>
        <h4 className="min-w-0 flex-1 truncate text-[13.5px] font-semibold text-ink">{f.title}</h4>
        <span className="flex items-baseline gap-1 text-[11.5px] text-role-system">
          <b className="text-[13px] font-semibold tabular-nums text-ink">
            {mineSpan(imp.s)}
            {Number(imp.usd) > 0 ? ` · ${mineUsd(imp.usd)}` : ""}
          </b>
          {imp.kind === "estimated" ? "估算" : "实测"}
        </span>
      </div>

      {m && (
        <div
          className={`mb-1.5 flex flex-wrap items-center gap-2 rounded-lg px-2 py-1 text-[11.5px] ${
            reached ? "bg-mine-good/8" : "bg-black/[0.03]"
          }`}
        >
          <span className="font-medium text-role-system">{mm?.label || m.id}</span>
          <span className="font-semibold tabular-nums text-mine-loss">
            {String(m.now ?? "—")}
            {m.unit || ""}
          </span>
          {m.target !== null && m.target !== undefined && (
            <>
              <span className="text-role-system">→</span>
              <span className="text-role-system">
                目标 {String(m.target)}
                {m.unit || ""}
              </span>
              <span className="relative h-1.5 w-16 overflow-hidden rounded-full bg-black/[0.06]">
                <i
                  className="absolute inset-y-0 left-0 rounded-full bg-mine-loss"
                  style={{ width: `${mm ? barPct(mm) : 0}%` }}
                />
              </span>
            </>
          )}
          {dt && (
            <span
              className={`tabular-nums ${
                dTone === "up"
                  ? "text-mine-loss"
                  : dTone === "down"
                    ? "text-mine-good"
                    : "text-role-system"
              }`}
            >
              较基线 {dt}
            </span>
          )}
        </div>
      )}

      {f.text && <p className="text-[12px] leading-snug text-ink">{f.text}</p>}
      {f.cause && (
        <p className="mt-0.5 text-[11.5px] leading-snug text-role-system">
          <b className="mr-1 font-semibold text-ink">原因</b>
          {f.cause}
        </p>
      )}
      {f.action && (
        <p className="mt-0.5 text-[11.5px] leading-snug text-role-assistant">
          <b className="mr-1 font-semibold">动作</b>
          {f.action}
        </p>
      )}
      {f.gate && (
        <p className="mt-0.5 text-[11.5px] leading-snug text-role-system">
          <b className="mr-1 font-semibold text-ink">闸门</b>
          {String(f.gate).replace(/^-\s*/, "")}
        </p>
      )}
      <Refs refs={f.refs} onTurn={onTurn} />
      <Ack f={f} onAck={onAck} />
    </article>
  );
}

/** ② 损耗排行 · 按 $ / 秒. */
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
        <SectionHead title="损耗排行 · 按 $ / 秒" count={0} />
        <p className="text-[11.5px] text-role-system">
          {data.n_rows ? "没有信号形成结论" : "还没有足够事件"}
        </p>
      </Section>
    );
  }

  const byUsd = list
    .filter((f) => Number(f.impact?.usd) > 0)
    .sort((a, b) => Number(b.impact.usd) - Number(a.impact.usd));
  const byS = [...list].sort((a, b) => Number(b.impact?.s || 0) - Number(a.impact?.s || 0));
  const barSpec = (rows: MineFinding[], useUsd: boolean) => ({
    kind: "bars" as const,
    unit: useUsd ? "USD" : "s",
    items: rows.map((f) => ({
      label: f.title || f.id,
      value: useUsd ? Number(f.impact.usd) : Number(f.impact?.s) || 0,
      sub: f.impact?.kind === "estimated" ? "估算" : "实测",
      color: sevOf(f.sev).color,
      jump: `loss-${f.id}`,
    })),
  });

  return (
    <Section id="mineLosses">
      <SectionHead
        title="损耗排行 · 按 $ / 秒"
        count={list.length}
        hint={hasEst ? "含估算项" : undefined}
      />
      <div className="flex flex-col gap-2">
        {byUsd.length > 0 && (
          <div>
            <div className="mb-0.5 text-[11px] text-role-system">按 $ 排序</div>
            <MineChart spec={barSpec(byUsd, true)} height={Math.max(30, byUsd.length * 28)} />
          </div>
        )}
        <div>
          <div className="mb-0.5 text-[11px] text-role-system">按秒排序（含墙钟空档）</div>
          <MineChart spec={barSpec(byS, false)} height={Math.max(30, byS.length * 28)} />
        </div>
      </div>
      <div className="mt-2.5 flex flex-col gap-2">
        {list.map((f, i) => (
          <LossCard key={f.id || i} f={f} i={i} data={data} onTurn={onTurn} onAck={onAck} />
        ))}
      </div>
    </Section>
  );
}
