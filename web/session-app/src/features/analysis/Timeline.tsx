import { localDateTime } from "@render";
import { type KeyboardEvent, type PointerEvent, useRef, useState } from "react";
import type { Mine, MineRef, MineTurn } from "../../api/mine";
import { cn } from "../../lib/cn";
import {
  localHm,
  mineSpan,
  mineUsd,
  PHASE_BADGE,
  pct,
  phaseLabel,
  phaseTotals,
  turnBars,
  turnReadout,
} from "./lib";
import { Card, Pill, Section, SectionHead } from "./Section";

const abbrev = (s: unknown, n = 44): string => {
  const t = String(s || "");
  if (t.length <= n) return t;
  const head = Math.ceil((n - 1) / 2);
  return `${t.slice(0, head)}…${t.slice(t.length - (n - 1 - head))}`;
};

function TurnDetail({ t, refs }: { t: MineTurn; refs: MineRef[] }) {
  const facts: [string, string][] = [
    ["工具", String(t.tools ?? "—")],
    ["失败", String(t.fails ?? 0)],
    ["重试", String(t.retries ?? 0)],
    ["工作", mineSpan(t.work_s)],
    ["等待", mineSpan(t.wait_s)],
    ["费用", t.cost_usd ? mineUsd(t.cost_usd) : "—"],
    ["输出 tok", String(t.tokens_out ?? "—")],
    ["写缓存", String(t.cache_write ?? "—")],
  ];
  return (
    <div className="border-t border-black/[0.06] bg-black/[0.015] px-4 py-3">
      <dl className="grid grid-cols-4 gap-x-4 gap-y-2">
        {facts.map(([k, v]) => (
          <div key={k}>
            <dt className="text-[11.5px] text-role-system">{k}</dt>
            <dd className="text-[13px] font-semibold tabular-nums text-ink">{v}</dd>
          </div>
        ))}
      </dl>
      <p className="mt-3 whitespace-pre-wrap break-words text-[13px] leading-normal text-ink">
        {t.prompt}
      </p>
      {t.nudge && (
        <p className="mt-2 text-[12.5px] text-mine-loss">
          短催回合：这一整个回合的成本计入返工损耗。
        </p>
      )}
      {refs.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {refs.slice(0, 6).map((r, i) => (
            <span
              // biome-ignore lint/suspicious/noArrayIndexKey: refs are positional evidence.
              key={`${r.label}-${i}`}
              className="h-6 rounded-[6px] bg-black/[0.05] px-2 text-[12px] leading-6 text-role-system"
            >
              {abbrev(r.label)}
              {r.exit_code ? ` · exit ${r.exit_code}` : ""}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * Turn strip. One column per turn (ordinal, not clock: a turn's width is not its
 * duration), height = tool wall clock on one scale, colour = phase, red tick =
 * the turn had a failure. Hover reads a turn in place (absolute readout, no
 * reflow); click / ← → opens that turn's row below.
 */
function Strip({
  turns,
  openTurn,
  onPick,
}: {
  turns: MineTurn[];
  openTurn: number | null;
  onPick: (n: number) => void;
}) {
  const bars = turnBars(turns);
  const [hover, setHover] = useState<number | null>(null);
  const plot = useRef<HTMLDivElement>(null);
  const at = (e: PointerEvent<HTMLDivElement>) => {
    const r = plot.current?.getBoundingClientRect();
    if (!r || !bars.length) return null;
    const i = Math.floor(((e.clientX - r.left) / r.width) * bars.length);
    return Math.max(0, Math.min(bars.length - 1, i));
  };
  const pinned = bars.findIndex((b) => b.index === openTurn);
  const shown = hover ?? (pinned >= 0 ? pinned : null);
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const cur = pinned >= 0 ? pinned : bars.length - 1;
    let next = cur;
    if (e.key === "ArrowLeft") next = Math.max(0, cur - 1);
    else if (e.key === "ArrowRight") next = Math.min(bars.length - 1, cur + 1);
    else if (e.key === "Home") next = 0;
    else if (e.key === "End") next = bars.length - 1;
    else return;
    e.preventDefault();
    const b = bars[next];
    if (b && b.index !== openTurn) onPick(b.index);
  };
  const read = shown != null ? turns[shown] : null;
  return (
    // pt (not the slider's margin) reserves the readout row: a margin would
    // collapse through this wrapper and put the readout on top of the bars.
    <div className="relative pt-8">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-6">
        {read && (
          <span className="inline-flex h-6 max-w-full items-center truncate rounded-[6px] bg-ink px-2 text-[12px] tabular-nums text-white">
            {turnReadout(read)}
          </span>
        )}
      </div>
      <div
        ref={plot}
        role="slider"
        tabIndex={0}
        aria-label="回合"
        aria-valuemin={1}
        aria-valuemax={bars.length}
        aria-valuenow={pinned >= 0 ? pinned + 1 : bars.length}
        aria-valuetext={read ? turnReadout(read) : undefined}
        onPointerMove={(e) => setHover(at(e))}
        onPointerLeave={() => setHover(null)}
        onClick={(e) => {
          const i = at(e as unknown as PointerEvent<HTMLDivElement>);
          const b = i != null ? bars[i] : null;
          if (b) onPick(b.index);
        }}
        onKeyDown={onKey}
        className="flex h-20 cursor-pointer items-end gap-[3px] border-b border-black/[0.10] outline-none focus-visible:ring-2 focus-visible:ring-accent/40"
      >
        {bars.map((b, i) => (
          <div key={b.index} className="relative flex h-full min-w-0 flex-1 items-end">
            <i
              className="block w-full transition-opacity"
              style={{
                height: `${b.pct}%`,
                background: b.color,
                opacity: shown != null && shown !== i ? 0.35 : 1,
              }}
            />
            {b.fail && (
              <i
                className="absolute inset-x-0 h-[3px] bg-mine-loss"
                style={{ bottom: `calc(${b.pct}% + 2px)` }}
              />
            )}
          </div>
        ))}
      </div>
      <div className="mt-1.5 flex justify-between text-[11.5px] tabular-nums text-role-system">
        <span>
          #{turns[0]?.index} · {localDateTime(turns[0]?.ts)}
        </span>
        <span>
          #{turns[turns.length - 1]?.index} · {localDateTime(turns[turns.length - 1]?.ts)}
        </span>
      </div>
    </div>
  );
}

/** ③ 回合: strip + phase legend + one row per turn, expanding in place. */
export function Timeline({
  data,
  openTurn,
  onToggleTurn,
}: {
  data: Mine;
  openTurn: number | null;
  onToggleTurn: (n: number) => void;
}) {
  const turns = data.turns || [];
  if (!turns.length) return null;
  const total = turns.reduce((a, t) => a + (Number(t.wall_s) || 0), 0);
  const maxWall = Math.max(1, ...turns.map((t) => Number(t.wall_s) || 0));
  const phases = phaseTotals(turns);
  const inst = data.window?.instances || [];
  const refsFor = (idx: number) =>
    (data.findings || []).flatMap((f) =>
      (f.refs || []).filter((r) => Number(r.turn) === Number(idx)),
    );
  const pick = (n: number) => {
    onToggleTurn(n);
    window.requestAnimationFrame(() =>
      document.getElementById(`turn-${n}`)?.scrollIntoView({ block: "nearest" }),
    );
  };

  return (
    <Section id="mineTimeline">
      <SectionHead
        title="回合"
        count={turns.length}
        hint={
          <>
            工具墙钟 <b className="font-semibold tabular-nums text-ink">{mineSpan(total)}</b>
          </>
        }
      />
      <Card>
        <Strip turns={turns} openTurn={openTurn} onPick={pick} />
        <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-role-system">
          {phases.map((p) => (
            <li key={p.phase} className="inline-flex items-center gap-1.5">
              <i className="size-2.5" style={{ background: p.color }} />
              {p.label}
              <b className="font-semibold tabular-nums text-ink">{mineSpan(p.s)}</b>
              <span className="tabular-nums">{pct(p.s, total).toFixed(0)}%</span>
            </li>
          ))}
          <li className="inline-flex items-center gap-1.5">
            <i className="h-[3px] w-2.5 bg-mine-loss" />
            有失败
          </li>
        </ul>
        {inst.length > 1 && (
          <p className="mt-2 text-[12px] text-role-system">
            窗口含 {inst.join("、")}，按事件时间合并。
          </p>
        )}
      </Card>

      <div className="mt-3 overflow-hidden rounded-[14px] border border-black/[0.06] bg-white">
        {turns.map((t, i) => {
          const open = Number(openTurn) === Number(t.index);
          const fail = Number(t.fails) > 0;
          return (
            <div
              key={t.index}
              id={`turn-${t.index}`}
              className={cn("scroll-mt-4", i > 0 && "border-t border-black/[0.06]")}
            >
              <button
                type="button"
                aria-expanded={open}
                onClick={() => onToggleTurn(t.index)}
                className={cn(
                  "grid w-full grid-cols-[44px_minmax(0,1fr)_auto] items-center gap-x-3 px-4 py-2.5 text-left transition-colors",
                  open ? "bg-black/[0.03]" : "hover:bg-black/[0.02]",
                )}
              >
                <span className="text-[13px] font-semibold tabular-nums text-ink">#{t.index}</span>
                <span className="min-w-0">
                  <span className="block truncate text-[13px] text-ink">{t.prompt}</span>
                  <span className="mt-1 flex items-center gap-2 text-[12px] tabular-nums text-role-system">
                    <Pill tone={PHASE_BADGE[t.phase] || PHASE_BADGE.other}>
                      {phaseLabel(t.phase)}
                    </Pill>
                    {localHm(t.ts)} · {Number(t.tools) || 0} 工具
                    {fail && <span className="text-mine-loss">· {Number(t.fails)} 失败</span>}
                    {t.cost_usd ? ` · ${mineUsd(t.cost_usd)}` : ""}
                  </span>
                </span>
                <span className="flex w-[88px] flex-col items-end gap-1.5">
                  <b className="text-[13px] font-semibold tabular-nums text-ink">
                    {mineSpan(t.wall_s)}
                  </b>
                  <span className="block h-1 w-full bg-black/[0.05]">
                    <i
                      className="block h-full"
                      style={{
                        width: `${Math.max(3, Math.round((100 * (Number(t.wall_s) || 0)) / maxWall))}%`,
                        background: fail ? "#c2410c" : "rgba(60,60,67,0.45)",
                      }}
                    />
                  </span>
                </span>
              </button>
              {open && <TurnDetail t={t} refs={refsFor(t.index)} />}
            </div>
          );
        })}
      </div>
    </Section>
  );
}
