import { localDateTime } from "@render";
import { type KeyboardEvent, type PointerEvent, useRef, useState } from "react";
import type { Mine, MineRef, MineTurn } from "../../api/mine";
import { cn } from "../../lib/cn";
import {
  dayBreaks,
  fmtValue,
  localHm,
  mineSpan,
  mineUsd,
  nextSort,
  PHASE_BADGE,
  pct,
  phaseLabel,
  phaseTotals,
  refHits,
  type SortState,
  STRIP_METRICS,
  type StripMetric,
  sortRows,
  stripValueText,
  turnBars,
  turnClues,
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
    ["输出", t.tokens_out ? fmtValue(t.tokens_out, "tok") : "—"],
    ["写缓存", t.cache_write ? fmtValue(t.cache_write, "tok") : "—"],
  ];
  return (
    <div className="border-t border-black/[0.06] bg-black/[0.015] px-4 py-3">
      <dl className="grid grid-cols-4 gap-x-4 gap-y-2 @2xl:grid-cols-8">
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
  metric,
  hits,
  hover,
  setHover,
}: {
  turns: MineTurn[];
  openTurn: number | null;
  onPick: (n: number) => void;
  metric: StripMetric;
  hits: Map<number, number>;
  hover: number | null;
  setHover: (i: number | null) => void;
}) {
  const bars = turnBars(turns, metric);
  const breaks = dayBreaks(turns);
  const maxHit = Math.max(1, ...hits.values());
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
  const readText = read
    ? `${turnReadout(read)}${metric !== "wall_s" ? ` · ${STRIP_METRICS.find((m) => m.id === metric)?.label} ${stripValueText(metric, (read as Record<string, unknown>)[metric])}` : ""}${hits.get(Number(read.index)) ? ` · 证据 ${hits.get(Number(read.index))}` : ""}`
    : "";
  return (
    // pt (not the slider's margin) reserves the readout row: a margin would
    // collapse through this wrapper and put the readout on top of the bars.
    <div className="relative pt-8">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-6">
        {read && (
          <span className="inline-flex h-6 max-w-full items-center truncate rounded-[6px] bg-ink px-2 text-[12px] tabular-nums text-white">
            {readText}
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
        aria-valuetext={read ? readText : undefined}
        onPointerMove={(e) => setHover(at(e))}
        onPointerLeave={() => setHover(null)}
        onClick={(e) => {
          const i = at(e as unknown as PointerEvent<HTMLDivElement>);
          const b = i != null ? bars[i] : null;
          if (b) onPick(b.index);
        }}
        onKeyDown={onKey}
        className="relative flex h-24 cursor-pointer items-end gap-[3px] border-b border-black/[0.10] outline-none focus-visible:ring-2 focus-visible:ring-accent/40"
      >
        {breaks.map((b) => (
          <span
            key={b.at}
            className="pointer-events-none absolute inset-y-0 border-l border-dashed border-black/15"
            style={{ left: `${(100 * b.at) / bars.length}%` }}
          >
            <span className="absolute left-1 top-0 whitespace-nowrap text-[10.5px] tabular-nums text-role-system">
              {b.label}
            </span>
          </span>
        ))}
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
      {hits.size > 0 && (
        <div className="mt-1 flex h-2 gap-[3px]" aria-hidden="true">
          {bars.map((b, i) => {
            const n = hits.get(b.index) || 0;
            return (
              <i
                key={b.index}
                className="block h-full min-w-0 flex-1"
                style={{
                  background: n ? `rgba(194,65,12,${0.25 + (0.75 * n) / maxHit})` : "transparent",
                  opacity: shown != null && shown !== i ? 0.4 : 1,
                }}
              />
            );
          })}
        </div>
      )}
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

type Col = { id: string; title: string; num: boolean; w: string };
const COLS: Col[] = [
  { id: "index", title: "#", num: true, w: "w-[44px]" },
  { id: "prompt", title: "用户首行", num: false, w: "" },
  { id: "tools", title: "工具", num: true, w: "w-[56px]" },
  { id: "fails", title: "失败", num: true, w: "w-[48px]" },
  { id: "cost_usd", title: "费用", num: true, w: "w-[72px]" },
  { id: "wall_s", title: "墙钟", num: true, w: "w-[96px]" },
];

const segBtn = (on: boolean) =>
  cn(
    "h-6 rounded-[6px] px-2 text-[12px] font-medium transition-colors",
    on ? "bg-white text-ink shadow-sm" : "text-role-system hover:text-ink",
  );

/** ③ 回合: strip (switchable height, evidence lane) + phase filter + sortable turn table. */
export function Timeline({
  data,
  openTurn,
  onToggleTurn,
}: {
  data: Mine;
  openTurn: number | null;
  onToggleTurn: (n: number) => void;
}) {
  const all = data.turns || [];
  const [metric, setMetric] = useState<StripMetric>("wall_s");
  const [phase, setPhase] = useState<string | null>(null);
  const [lens, setLens] = useState<string>("");
  const [sort, setSort] = useState<SortState>(null);
  const [hover, setHover] = useState<number | null>(null);
  if (!all.length) return null;
  const findings = (data.findings || []).filter((f) => (f.refs || []).some((r) => r.turn != null));
  const lensF = findings.find((f) => f.id === lens);
  const hits = refHits(lensF ? lensF.refs : findings.flatMap((f) => f.refs || []));
  const turns = phase ? all.filter((t) => t.phase === phase) : all;
  const total = all.reduce((a, t) => a + (Number(t.wall_s) || 0), 0);
  const maxWall = Math.max(1, ...all.map((t) => Number(t.wall_s) || 0));
  const phases = phaseTotals(all);
  const clues = turnClues(data.blocks as Parameters<typeof turnClues>[0]);
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
  const rows = sortRows(turns as unknown as Record<string, unknown>[], sort, (k) =>
    COLS.some((c) => c.id === k && c.num),
  ) as unknown as MineTurn[];
  const hoverIdx = hover != null ? turns[hover]?.index : null;
  const failN = all.filter((t) => Number(t.fails) > 0).length;
  const costSum = all.reduce((a, t) => a + (Number(t.cost_usd) || 0), 0);

  return (
    <Section id="mineTimeline">
      <SectionHead
        title="回合"
        count={all.length}
        hint={
          <>
            工具墙钟 <b className="font-semibold tabular-nums text-ink">{mineSpan(total)}</b>
            {failN > 0 && <span className="tabular-nums text-mine-loss">· {failN} 回合有失败</span>}
            {costSum > 0 && <span className="tabular-nums">· {mineUsd(costSum)}</span>}
          </>
        }
      />
      <Card>
        <div className="flex flex-wrap items-center gap-2">
          <fieldset aria-label="高度" className="inline-flex rounded-[8px] bg-black/[0.06] p-0.5">
            {STRIP_METRICS.map((m) => (
              <button
                key={m.id}
                type="button"
                aria-pressed={metric === m.id}
                onClick={() => setMetric(m.id)}
                className={segBtn(metric === m.id)}
              >
                {m.label}
              </button>
            ))}
          </fieldset>
          {findings.length > 0 && (
            <label className="ml-auto flex items-center gap-1.5 text-[12px] text-role-system">
              证据
              <select
                value={lens}
                onChange={(e) => setLens(e.target.value)}
                className="h-6 max-w-[200px] rounded-[6px] bg-black/[0.05] px-1.5 text-[12px] text-ink outline-none focus:ring-2 focus:ring-accent/30"
              >
                <option value="">全部发现</option>
                {findings.map((f) => (
                  <option key={f.id} value={f.id}>
                    {f.title.split("：")[0]}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
        <div className="mt-2">
          <Strip
            turns={turns}
            openTurn={openTurn}
            onPick={pick}
            metric={metric}
            hits={hits}
            hover={hover}
            setHover={setHover}
          />
        </div>
        <ul className="mt-2.5 flex flex-wrap gap-1 text-[12px] text-role-system">
          {phases.map((p) => {
            const on = phase === p.phase;
            return (
              <li key={p.phase}>
                <button
                  type="button"
                  aria-pressed={on}
                  onClick={() => setPhase(on ? null : p.phase)}
                  className={cn(
                    "inline-flex h-6 items-center gap-1.5 rounded-[6px] px-1.5 transition-colors",
                    on ? "bg-black/[0.07] text-ink" : "hover:bg-black/[0.04]",
                    phase && !on && "opacity-50",
                  )}
                >
                  <i className="size-2.5" style={{ background: p.color }} />
                  {p.label}
                  <b className="font-semibold tabular-nums text-ink">{mineSpan(p.s)}</b>
                  <span className="tabular-nums">{pct(p.s, total).toFixed(0)}%</span>
                </button>
              </li>
            );
          })}
          <li className="inline-flex h-6 items-center gap-1.5 px-1.5">
            <i className="h-[3px] w-2.5 bg-mine-loss" />
            有失败
          </li>
          {hits.size > 0 && (
            <li className="inline-flex h-6 items-center gap-1.5 px-1.5">
              <i className="h-2 w-2.5 bg-mine-loss/60" />
              {lensF ? "该发现的证据" : "发现证据"}（{hits.size} 回合）
            </li>
          )}
        </ul>
        {inst.length > 1 && (
          <p className="mt-1 text-[12px] text-role-system">
            窗口含 {inst.join("、")}，按事件时间合并。
          </p>
        )}

        <table className="mt-3 w-full table-fixed border-collapse text-[12.5px]">
          <thead>
            <tr>
              {COLS.map((c) => {
                const on = sort?.key === c.id;
                return (
                  <th
                    key={c.id}
                    aria-sort={on ? (sort?.dir === "asc" ? "ascending" : "descending") : "none"}
                    className={cn("border-b border-black/[0.08] p-0 font-normal", c.w)}
                  >
                    <button
                      type="button"
                      onClick={() => setSort((s) => nextSort(s, c.id))}
                      className={cn(
                        "h-7 w-full truncate px-2 text-[11.5px] hover:text-ink",
                        c.num ? "text-right" : "text-left",
                        on ? "font-semibold text-ink" : "text-role-system",
                      )}
                    >
                      {c.title}
                      {on ? (sort?.dir === "asc" ? " ↑" : " ↓") : ""}
                    </button>
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {rows.map((t) => {
              const open = Number(openTurn) === Number(t.index);
              const fail = Number(t.fails) > 0;
              const clue = clues.get(String(t.ts));
              const lit = hoverIdx === t.index || open;
              const ev = hits.get(Number(t.index)) || 0;
              return (
                <TurnRow
                  key={t.index}
                  t={t}
                  open={open}
                  lit={lit}
                  fail={fail}
                  ev={ev}
                  clue={clue}
                  maxWall={maxWall}
                  refs={open ? refsFor(t.index) : []}
                  onToggle={() => onToggleTurn(t.index)}
                  onHover={(on) => setHover(on ? turns.indexOf(t) : null)}
                />
              );
            })}
          </tbody>
        </table>
      </Card>
    </Section>
  );
}

function TurnRow({
  t,
  open,
  lit,
  fail,
  ev,
  clue,
  maxWall,
  refs,
  onToggle,
  onHover,
}: {
  t: MineTurn;
  open: boolean;
  lit: boolean;
  fail: boolean;
  ev: number;
  clue?: { path: boolean; repo: boolean };
  maxWall: number;
  refs: MineRef[];
  onToggle: () => void;
  onHover: (on: boolean) => void;
}) {
  const td = "h-8 border-b border-black/[0.05] px-2 tabular-nums";
  return (
    <>
      <tr
        id={`turn-${t.index}`}
        aria-expanded={open}
        tabIndex={0}
        onClick={onToggle}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            onToggle();
          }
        }}
        onPointerEnter={() => onHover(true)}
        onPointerLeave={() => onHover(false)}
        className={cn(
          "scroll-mt-4 cursor-pointer outline-none focus-visible:bg-accent/[0.06]",
          lit ? "bg-black/[0.035]" : "hover:bg-black/[0.02]",
        )}
      >
        <td className={cn(td, "text-right font-semibold text-ink")}>
          {ev > 0 && (
            <i className="mr-1 inline-block size-1.5 rounded-full bg-mine-loss align-middle" />
          )}
          {t.index}
        </td>
        <td className={cn(td, "text-ink")}>
          <span className="flex min-w-0 items-center gap-1.5">
            <Pill tone={PHASE_BADGE[t.phase] || PHASE_BADGE.other}>{phaseLabel(t.phase)}</Pill>
            <span className="shrink-0 text-[11.5px] text-role-system">{localHm(t.ts)}</span>
            <span className="min-w-0 truncate">{t.prompt}</span>
            {t.nudge && <span className="shrink-0 text-[11.5px] text-mine-loss">短催</span>}
            {clue && !clue.path && !clue.repo && (
              <span className="shrink-0 text-[11px] text-honey" title="prompt 没有路径/仓库线索">
                无线索
              </span>
            )}
          </span>
        </td>
        <td className={cn(td, "text-right text-ink")}>{Number(t.tools) || 0}</td>
        <td
          className={cn(
            td,
            "text-right",
            fail ? "font-semibold text-mine-loss" : "text-role-system",
          )}
        >
          {Number(t.fails) || 0}
        </td>
        <td className={cn(td, "text-right text-mine-money")}>
          {t.cost_usd ? mineUsd(t.cost_usd) : <span className="text-role-system">—</span>}
        </td>
        <td className={cn(td, "text-right text-ink")}>
          <span className="relative flex items-center justify-end">
            <i
              className="absolute inset-y-[3px] right-0"
              style={{
                width: `${Number(t.wall_s) > 0 ? Math.max(3, Math.round((100 * (Number(t.wall_s) || 0)) / maxWall)) : 0}%`,
                background: fail ? "rgba(194,65,12,0.22)" : "rgba(60,60,67,0.12)",
              }}
            />
            <span className="relative font-semibold">{mineSpan(t.wall_s)}</span>
          </span>
        </td>
      </tr>
      {open && (
        <tr>
          <td colSpan={COLS.length} className="p-0">
            <TurnDetail t={t} refs={refs} />
          </td>
        </tr>
      )}
    </>
  );
}
