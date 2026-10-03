import { localDateTime } from "@render";
import type { Mine, MineRef, MineTurn } from "../../api/mine";
import { mineSpan, mineUsd, PHASE_BADGE, phaseColor, phaseLabel } from "./lib";
import { MineChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

const abbrev = (s: unknown, n = 46): string => {
  const t = String(s || "");
  if (t.length <= n) return t;
  const head = Math.ceil((n - 1) / 2);
  return `${t.slice(0, head)}…${t.slice(t.length - (n - 1 - head))}`;
};

function TurnDetail({ t, refs }: { t: MineTurn; refs: MineRef[] }) {
  const chips: [string, unknown][] = [
    ["工具", t.tools],
    ["失败", t.fails],
    ["重试", t.retries],
    ["工作", mineSpan(t.work_s)],
    ["等待", mineSpan(t.wait_s)],
    ["费用", t.cost_usd ? mineUsd(t.cost_usd) : "—"],
    ["输出 tok", t.tokens_out],
    ["写缓存", t.cache_write],
  ];
  return (
    <div className="mt-1 rounded-lg border border-black/5 bg-white px-2.5 py-2">
      <div className="flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-role-system">
        {chips.map(([k, v]) => (
          <span key={k}>
            {k} <b className="font-semibold text-ink tabular-nums">{String(v ?? "—")}</b>
          </span>
        ))}
      </div>
      <p className="mt-1 text-[11.5px] leading-snug text-role-system">
        <b className="mr-1 font-semibold text-ink">prompt</b>
        {t.prompt}
      </p>
      {t.nudge && (
        <p className="mt-0.5 text-[11.5px] leading-snug text-role-system">
          <b className="mr-1 font-semibold text-ink">性质</b>
          短催回合：这一整个回合的成本计入返工损耗。
        </p>
      )}
      {refs.length > 0 && (
        <div className="mt-1 flex flex-wrap gap-1">
          {refs.slice(0, 6).map((r, i) => (
            <span
              // biome-ignore lint/suspicious/noArrayIndexKey: refs are positional evidence.
              key={`${r.label}-${i}`}
              className="rounded-md bg-black/[0.04] px-1.5 py-0.5 text-[10.5px] text-role-system"
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

/** ③ 回合时间轴: phase colours, wall-clock bars, fail dots, click to expand. */
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
  const inst = (data.window?.instances || []).join("、");
  const refsFor = (idx: number) =>
    (data.findings || []).flatMap((f) =>
      (f.refs || []).filter((r) => Number(r.turn) === Number(idx)),
    );

  return (
    <Section id="mineTimeline">
      <SectionHead
        title="回合时间轴"
        count={turns.length}
        hint="柱=墙钟（红点=该回合有失败）· 点击就地展开"
      />
      {inst.includes("、") && (
        <p className="mb-1 text-[11.5px] text-role-system">
          <b className="mr-1 font-semibold text-ink">多实例</b>窗口含 {inst}，按事件时间合并。
        </p>
      )}
      <div className="mb-0.5 flex items-baseline gap-2 text-[11.5px] text-role-system">
        <span>每回合墙钟</span>
        <b className="text-[13px] font-semibold tabular-nums text-ink">{mineSpan(total)}</b>
      </div>
      <MineChart
        spec={{
          kind: "columns",
          unit: "s",
          items: turns.map((t) => ({
            label: localDateTime(t.ts) || `#${t.index}`,
            value: Number(t.wall_s) || 0,
            color: phaseColor(t.phase, 0),
            flag: Number(t.fails) > 0,
            jump: t.index,
            note: `${Number(t.tools)} 工具${t.fails ? ` · ${Number(t.fails)} 失败` : ""}`,
          })),
        }}
        height={52}
        onJump={(j) => onToggleTurn(Number(j))}
      />
      <div className="mb-1.5 flex justify-between text-[10px] text-role-system">
        <span>{localDateTime(turns[0].ts)}</span>
        <span>{localDateTime(turns[turns.length - 1].ts)}</span>
      </div>

      <div className="flex flex-col gap-1">
        {turns.map((t) => {
          const open = Number(openTurn) === Number(t.index);
          return (
            <div key={t.index}>
              <button
                type="button"
                onClick={() => onToggleTurn(t.index)}
                className={`flex w-full flex-col gap-1 rounded-lg border px-2.5 py-1.5 text-left transition-colors ${
                  open
                    ? "border-black/10 bg-white"
                    : "border-transparent bg-white/60 hover:bg-white"
                }`}
              >
                <span className="flex w-full items-center gap-2">
                  <span
                    className={`rounded-full px-1.5 py-0.5 text-[10px] font-semibold ${
                      PHASE_BADGE[t.phase] || PHASE_BADGE.other
                    }`}
                  >
                    {phaseLabel(t.phase)}
                  </span>
                  <b className="text-[11.5px] font-semibold text-ink tabular-nums">#{t.index}</b>
                  <i className="text-[10.5px] not-italic text-role-system">{localDateTime(t.ts)}</i>
                  <span className="ml-auto text-[11px] text-role-system tabular-nums">
                    {Number(t.tools)} 工具
                    {t.fails ? ` · ${Number(t.fails)} 失败` : ""}
                    {t.cost_usd ? ` · ${mineUsd(t.cost_usd)}` : ""} · {mineSpan(t.wall_s)}
                  </span>
                </span>
                <span className="w-full truncate text-[11.5px] text-ink">{t.prompt}</span>
                <span className="h-1 w-full overflow-hidden rounded-full bg-black/[0.05]">
                  <i
                    className="block h-full rounded-full"
                    style={{
                      width: `${Math.max(3, Math.round((100 * (Number(t.wall_s) || 0)) / Math.max(1, ...turns.map((x) => Number(x.wall_s) || 0))))}%`,
                      background: Number(t.fails) > 0 ? "#c2410c" : phaseColor(t.phase, 0),
                    }}
                  />
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
