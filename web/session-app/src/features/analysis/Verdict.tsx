import { useState } from "react";
import type { Mine } from "../../api/mine";
import { cn } from "../../lib/cn";
import {
  dailyCost,
  deltaText,
  deltaTone,
  fmtValue,
  KPI_IDS,
  lossParts,
  metricOf,
  metricText,
  mineSpan,
  mineUsd,
  pct,
  type Tone,
  verdictHeadline,
} from "./lib";
import { Card, Section } from "./Section";

const TONE_TEXT: Record<Tone, string> = {
  good: "text-mine-good",
  ok: "text-honey",
  warn: "text-mine-loss",
  bad: "text-red-700",
};
const TONE_RING: Record<Tone, string> = {
  good: "#2e7d32",
  ok: "#c47a2c",
  warn: "#c2410c",
  bad: "#b91c1c",
};

/** Score as a ring: the number is the reading, the arc only restates it. */
function ScoreRing({ score, grade, tone }: { score: number | null; grade: string; tone: Tone }) {
  const r = 30;
  const c = 2 * Math.PI * r;
  const v = Math.max(0, Math.min(100, score ?? 0));
  return (
    <div
      className="relative size-[76px] shrink-0"
      role="img"
      aria-label={`健康分 ${score ?? "—"} ${grade}`}
    >
      <svg viewBox="0 0 76 76" className="size-full -rotate-90" aria-hidden="true">
        <circle cx="38" cy="38" r={r} fill="none" stroke="rgba(60,60,67,0.10)" strokeWidth="6" />
        <circle
          cx="38"
          cy="38"
          r={r}
          fill="none"
          stroke={TONE_RING[tone]}
          strokeWidth="6"
          strokeLinecap="round"
          strokeDasharray={`${(c * v) / 100} ${c}`}
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <b className={cn("text-[24px] font-bold leading-none tabular-nums", TONE_TEXT[tone])}>
          {score ?? "—"}
        </b>
        <span className="mt-1 text-[11px] text-role-system">{grade}</span>
      </div>
    </div>
  );
}

/**
 * Loss composition: one hue (loss), parts ordered by size, numbers beside every
 * mark. Hovering a legend row lights its segment; clicking jumps to the card.
 */
function LossBar({ data, onJump }: { data: Mine; onJump: (id: string) => void }) {
  const { parts, totalS } = lossParts(data);
  const [hot, setHot] = useState<string | null>(null);
  if (!parts.length) return null;
  return (
    <div className="mt-4">
      <div className="flex h-2.5 gap-[3px]" aria-hidden="true">
        {parts.map((p) => (
          <i
            key={p.id}
            className="block h-full transition-opacity"
            style={{
              flex: `${Math.max(p.s, totalS * 0.012)} 1 0`,
              background: p.color,
              opacity: hot && hot !== p.id ? 0.25 : 1,
            }}
          />
        ))}
      </div>
      <ul className="mt-2.5 flex flex-col">
        {parts.map((p) => (
          <li key={p.id}>
            <button
              type="button"
              onMouseEnter={() => setHot(p.id)}
              onMouseLeave={() => setHot(null)}
              onFocus={() => setHot(p.id)}
              onBlur={() => setHot(null)}
              onClick={() => onJump(`loss-${p.id}`)}
              className="flex h-7 w-full items-center gap-2 rounded-[6px] px-1 text-left text-[12.5px] hover:bg-black/[0.03]"
            >
              <i className="size-2.5 shrink-0" style={{ background: p.color }} />
              <span className="min-w-0 flex-1 truncate text-ink">{p.label}</span>
              <b className="font-semibold tabular-nums text-ink">{mineSpan(p.s)}</b>
              <span className="w-11 text-right tabular-nums text-role-system">
                {pct(p.s, totalS).toFixed(0)}%
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Cost by day: columns on one scale, hover reads the day. Zero stays zero. */
function DailyCost({ data }: { data: Mine }) {
  const days = dailyCost(data);
  const [hot, setHot] = useState<number | null>(null);
  if (days.length < 2) return null;
  const max = Math.max(...days.map((d) => d.usd), 0);
  const d = hot != null ? days[hot] : null;
  const sum = days.reduce((a, x) => a + x.usd, 0);
  return (
    <div className="mt-auto pt-4">
      <div className="mb-1.5 flex items-baseline justify-between gap-2 text-[12px] text-role-system">
        <span>按天</span>
        <span className="tabular-nums">
          {d ? (
            <>
              {d.day.slice(5)} · <b className="font-semibold text-mine-money">{mineUsd(d.usd)}</b> ·{" "}
              {d.n} 回合
            </>
          ) : (
            <>
              {days.length} 天 · 日均 {mineUsd(sum / days.length)}
            </>
          )}
        </span>
      </div>
      <div
        className="flex h-12 items-end gap-1 border-b border-black/[0.10]"
        onPointerLeave={() => setHot(null)}
      >
        {days.map((x, i) => (
          <span
            key={x.day}
            onPointerEnter={() => setHot(i)}
            className="flex h-full min-w-0 flex-1 cursor-default items-end"
          >
            <i
              className="block w-full bg-mine-money transition-opacity"
              style={{
                height: `${max > 0 && x.usd > 0 ? Math.max(4, Math.round((100 * x.usd) / max)) : 0}%`,
                opacity: hot != null && hot !== i ? 0.35 : 1,
              }}
            />
          </span>
        ))}
      </div>
      <div className="mt-1 flex justify-between text-[11px] tabular-nums text-role-system">
        <span>{days[0].day.slice(5)}</span>
        <span>{days[days.length - 1].day.slice(5)}</span>
      </div>
    </div>
  );
}

/** Input tokens served from cache vs not: a meter, not a ring that is always full. */
function CostCard({ data }: { data: Mine }) {
  const s = data.summary || {};
  const cost = metricOf(data, "cost_usd");
  const hit = metricOf(data, "cache_hit_pct");
  const cache = data.series?.cache;
  const read = Number(cache?.read) || 0;
  const uncached = Number(cache?.uncached) || 0;
  if (!s.usage_turns) {
    return (
      <Card className="flex flex-col justify-center">
        <span className="text-[12px] text-role-system">费用</span>
        <b className="mt-1 text-[20px] font-semibold text-ink">—</b>
        <span className="mt-1 text-[12px] text-role-system">
          无计费数据（本窗口没有 usage 回合）
        </span>
      </Card>
    );
  }
  const dCost = deltaText(cost);
  const dHit = deltaText(hit);
  return (
    <Card className="flex flex-col">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-[12px] text-role-system">费用</span>
        <Delta text={dCost} tone={deltaTone(cost)} />
      </div>
      <b className="mt-1 text-[28px] font-semibold leading-none tracking-[-0.02em] tabular-nums text-mine-money">
        {mineUsd(s.cost_usd)}
      </b>
      <div className="mt-4 flex items-baseline justify-between gap-3">
        <span className="text-[12px] text-role-system">
          缓存命中 <b className="font-semibold tabular-nums text-ink">{s.cache_hit_pct}%</b>
        </span>
        <Delta text={dHit} tone={deltaTone(hit)} />
      </div>
      <div className="mt-2 flex h-2.5 gap-[3px]" aria-hidden="true">
        <i className="block h-full bg-mine-money" style={{ flex: `${read} 1 0` }} />
        <i
          className="block h-full bg-honey"
          style={{ flex: `${Math.max(uncached, (read + uncached) * 0.012)} 1 0` }}
        />
      </div>
      <dl className="mt-2.5 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[12px]">
        <dt className="flex items-center gap-1.5 text-role-system">
          <i className="size-2.5 bg-mine-money" />
          缓存读
        </dt>
        <dd className="text-right font-semibold tabular-nums text-ink">{fmtValue(read, "tok")}</dd>
        <dt className="flex items-center gap-1.5 text-role-system">
          <i className="size-2.5 bg-honey" />
          未缓存输入
        </dt>
        <dd className="text-right font-semibold tabular-nums text-ink">
          {fmtValue(uncached, "tok")}
        </dd>
        <dt className="pl-4 text-role-system">输出</dt>
        <dd className="text-right tabular-nums text-ink">{fmtValue(s.tokens_out, "tok")}</dd>
        <dt className="pl-4 text-role-system">写缓存</dt>
        <dd className="text-right tabular-nums text-ink">{fmtValue(s.cache_write, "tok")}</dd>
      </dl>
      <DailyCost data={data} />
    </Card>
  );
}

function Delta({ text, tone }: { text: string; tone: string }) {
  if (!text) return null;
  return (
    <span
      className={cn(
        "text-[11.5px] tabular-nums",
        tone === "up" ? "text-mine-loss" : tone === "down" ? "text-mine-good" : "text-role-system",
      )}
      title="较对照窗口"
    >
      {text}
    </span>
  );
}

/** ① 损耗判定: verdict card (1.618) + cost card (1), then the KPI grid. */
export function Verdict({ data, onJump }: { data: Mine; onJump: (id: string) => void }) {
  const v = verdictHeadline(data);
  const loop = data.loop;
  const kpis = KPI_IDS.map((id) => metricOf(data, id)).filter(
    (m): m is NonNullable<typeof m> => !!m,
  );
  return (
    <Section id="mineVerdict">
      <div className="grid grid-cols-1 gap-3 @xl:grid-cols-[minmax(0,1.618fr)_minmax(0,1fr)]">
        <Card>
          <div className="flex items-center gap-4">
            <ScoreRing score={v.score} grade={v.grade} tone={v.tone} />
            <div className="min-w-0">
              <h3 className="text-[17px] font-semibold leading-snug tracking-[-0.02em] text-ink">
                {v.title}
              </h3>
              <p className="mt-1 text-[12.5px] leading-normal text-role-system">{v.detail}</p>
            </div>
          </div>
          <LossBar data={data} onJump={onJump} />
          {v.idle && <p className="mt-2 text-[12px] leading-normal text-role-system">{v.idle}</p>}
          {loop && (
            <p className="mt-3 border-t border-black/[0.06] pt-3 text-[12.5px] text-role-system">
              <b className="mr-1.5 font-semibold text-role-assistant">闭环</b>
              声明 {loop.total} 条 · 已闭环 {(loop.closed || []).length} · 未改善{" "}
              {(loop.open || []).length}
              {(loop.dismissed || []).length ? ` · 已忽略 ${(loop.dismissed || []).length}` : ""}
            </p>
          )}
        </Card>
        <CostCard data={data} />
      </div>

      {kpis.length > 0 && (
        <Card className="mt-3 px-0 py-3">
          <dl className="grid grid-cols-2 gap-y-3 @md:grid-cols-4">
            {kpis.map((m) => (
              <div
                key={m.id}
                className="flex flex-col gap-0.5 border-black/[0.06] px-4 [&:not(:nth-child(2n+1))]:border-l @md:[&:not(:nth-child(2n+1))]:border-l-0 @md:[&:not(:nth-child(4n+1))]:border-l"
                title={m.note || undefined}
              >
                <dt className="text-[11.5px] text-role-system">{m.label}</dt>
                <dd className="flex items-baseline gap-1.5">
                  <b className="text-[17px] font-semibold tracking-[-0.01em] tabular-nums text-ink">
                    {metricText(m)}
                  </b>
                  <Delta text={deltaText(m)} tone={deltaTone(m)} />
                </dd>
              </div>
            ))}
          </dl>
        </Card>
      )}
    </Section>
  );
}
