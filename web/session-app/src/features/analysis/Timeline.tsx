import { localDateTime } from "@render";
import type { Mine, MineRef, MineTurn } from "../../api/mine";
import { mineSpan, mineUsd, PHASE_BADGE, phaseColor, phaseLabel } from "./lib";
import { MineChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

const abbrev = (s: unknown, n = 44): string => {
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
    <div className="mt-1.5 rounded-[12px] border border-black/[0.06] bg-white p-3">
      <div className="flex flex-wrap gap-x-4 gap-y-1.5 text-[12px] text-role-system">
        {chips.map(([k, v]) => (
          <span key={k}>
            {k} <b className="font-semibold text-ink tabular-nums">{String(v ?? "—")}</b>
          </span>
        ))}
      </div>
      <p className="mt-2 text-[12.5px] leading-relaxed text-role-system">
        <b className="mr-1.5 font-semibold text-ink">prompt</b>
        {t.prompt}
      </p>
      {t.nudge && (
        <p className="mt-1 text-[12.5px] leading-relaxed text-role-system">
          <b className="mr-1.5 font-semibold text-ink">性质</b>
          短催回合：这一整个回合的成本计入返工损耗。
        </p>
      )}
      {refs.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5">
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
  const maxWall = Math.max(1, ...turns.map((t) => Number(t.wall_s) || 0));
  const inst = (data.window?.instances || []).join("、");
  const refsFor = (idx: number) =>
    (data.findings || []).flatMap((f) =>
      (f.refs || []).filter((r) => Number(r.turn) === Number(idx)),
    );

  return (
    <Section id="mineTimeline">
      <SectionHead title="回合时间轴" count={turns.length} hint="柱=墙钟（红点=失败）· 点击展开" />
      {inst.includes("、") && (
        <p className="mb-2 text-[12.5px] text-role-system">
          <b className="mr-1.5 font-semibold text-ink">多实例</b>窗口含 {inst}，按事件时间合并。
        </p>
      )}
      <div className="mb-1.5 flex items-baseline gap-2 text-[12px] text-role-system">
        <span>每回合墙钟</span>
        <b className="text-[15px] font-semibold tabular-nums text-ink">{mineSpan(total)}</b>
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
        height={64}
        onJump={(j) => onToggleTurn(Number(j))}
      />
      <div className="mb-3 mt-1 flex justify-between text-[11.5px] text-role-system">
        <span>{localDateTime(turns[0].ts)}</span>
        <span>{localDateTime(turns[turns.length - 1].ts)}</span>
      </div>

      <div className="flex flex-col gap-2">
        {turns.map((t) => {
          const open = Number(openTurn) === Number(t.index);
          return (
            <div key={t.index}>
              <button
                type="button"
                onClick={() => onToggleTurn(t.index)}
                className={`flex w-full flex-col gap-2 rounded-[12px] border p-3 text-left transition-colors ${
                  open
                    ? "border-black/[0.10] bg-white"
                    : "border-black/[0.06] bg-white hover:bg-black/[0.02]"
                }`}
              >
                <span className="flex w-full items-center gap-2.5">
                  <span
                    className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${
                      PHASE_BADGE[t.phase] || PHASE_BADGE.other
                    }`}
                  >
                    {phaseLabel(t.phase)}
                  </span>
                  <b className="text-[12.5px] font-semibold text-ink tabular-nums">#{t.index}</b>
                  <i className="text-[11.5px] not-italic text-role-system">{localDateTime(t.ts)}</i>
                  <span className="ml-auto text-[12px] text-role-system tabular-nums">
                    {Number(t.tools)} 工具
                    {t.fails ? ` · ${Number(t.fails)} 失败` : ""}
                    {t.cost_usd ? ` · ${mineUsd(t.cost_usd)}` : ""} · {mineSpan(t.wall_s)}
                  </span>
                </span>
                <span className="w-full truncate text-[13px] text-ink">{t.prompt}</span>
                <span className="h-1.5 w-full overflow-hidden bg-black/[0.05]">
                  <i
                    className="block h-full"
                    style={{
                      width: `${Math.max(3, Math.round((100 * (Number(t.wall_s) || 0)) / maxWall))}%`,
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
