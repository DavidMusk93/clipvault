import type { Mine } from "../../api/mine";
import { deltaText, deltaTone, metricOf, mineSpan, mineUsd } from "./lib";
import { CompositionBar, MineChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

const scoreClass = (score: number) =>
  score >= 85
    ? "text-mine-good"
    : score >= 70
      ? "text-honey"
      : score >= 50
        ? "text-mine-loss"
        : "text-red-700";

/** ① 损耗判定: score + KPI + 时间/钱构成 + 缓存环形. */
export function Verdict({ data }: { data: Mine }) {
  const s = data.summary || {};
  const h = s.health || { score: 0, grade: "" };
  const flow = s.flow || {};
  const losses = data.losses || [];
  const lossS = losses.reduce((a, l) => a + (Number(l.s) || 0), 0);
  const lossUsd = losses.reduce((a, l) => a + (Number(l.usd) || 0), 0);
  const score = Number(h.score) || 0;

  const kpis = [
    { label: "工作秒", value: mineSpan(s.work_s), id: "work_s", tone: "text-mine-time" },
    { label: "等待秒", value: mineSpan(s.wait_s), id: "wait_s", tone: "text-mine-time" },
    { label: "可归因损耗", value: mineSpan(lossS), id: "loss_s", tone: "text-mine-loss" },
    { label: "失败调用", value: String(s.fail_n ?? 0), id: "fail_n", tone: "text-mine-loss" },
    {
      label: "额外往返",
      value: String(flow.extra_roundtrips ?? 0),
      id: "extra_trips",
      tone: "text-mine-loss",
    },
    {
      label: "费用",
      value: s.usage_turns ? mineUsd(s.cost_usd) : "—",
      id: "cost_usd",
      tone: "text-mine-money",
    },
    {
      label: "缓存命中",
      value: s.usage_turns ? `${s.cache_hit_pct}%` : "—",
      id: "cache_hit_pct",
      tone: "text-mine-money",
    },
    {
      label: "工具/回合",
      value: String(s.tools_per_turn ?? 0),
      id: "tools_per_turn",
      tone: "text-ink",
    },
  ];

  const workOk = Math.max(0, (Number(s.work_s) || 0) - (Number(s.fail_s) || 0));
  const timeItems = [
    { label: "工作（不含失败）", value: workOk, color: "#0071e3" },
    { label: "等待", value: Number(s.wait_s) || 0, color: "rgba(60,60,67,0.38)" },
    { label: "失败", value: Number(s.fail_s) || 0, color: "#c2410c" },
  ];
  const tokenItems = [
    { label: "输出", value: Number(s.tokens_out) || 0, color: "#2f8f83" },
    { label: "写缓存", value: Number(s.cache_write) || 0, color: "#c47a2c" },
    { label: "缓存读", value: Number(s.cache_read) || 0, color: "rgba(47,143,131,0.40)" },
  ];
  const cache = data.series?.cache;
  const cacheItems = [
    { label: "缓存读", value: Number(cache?.read) || 0, color: "#2f8f83" },
    { label: "未缓存输入", value: Number(cache?.uncached) || 0, color: "#c47a2c" },
  ];
  const loop = data.loop;

  return (
    <Section id="mineVerdict">
      <SectionHead
        title="损耗判定"
        count={losses.length}
        hint={`可归因 ${mineSpan(lossS)}${lossUsd ? ` · ${mineUsd(lossUsd)}` : ""}`}
      />
      <div className="grid grid-cols-[78px_1.618fr_1fr] gap-x-3.5 gap-y-2.5 rounded-2xl border border-black/5 bg-white px-3.5 py-3">
        <div className="row-span-2 flex flex-col items-center justify-center border-r border-black/5 pr-3.5">
          <b className={`text-[34px] font-bold leading-none tabular-nums ${scoreClass(score)}`}>
            {h.score ?? "—"}
          </b>
          <span className="mt-1 text-[11.5px] text-role-system">{h.grade}</span>
        </div>

        <div className="col-span-2 flex flex-wrap gap-x-4 gap-y-1">
          {kpis.map((k) => {
            const m = metricOf(data, k.id);
            const d = deltaText(m);
            const tone = deltaTone(m);
            return (
              <div key={k.id} className="flex min-w-[62px] flex-col">
                <b className={`text-[16px] font-semibold leading-tight tabular-nums ${k.tone}`}>
                  {k.value}
                </b>
                <span className="text-[11px] text-role-system">{k.label}</span>
                {d && (
                  <em
                    className={`text-[10.5px] not-italic ${
                      tone === "up"
                        ? "text-mine-loss"
                        : tone === "down"
                          ? "text-mine-good"
                          : "text-role-system"
                    }`}
                  >
                    {d}
                  </em>
                )}
              </div>
            );
          })}
        </div>

        <div className="flex min-w-0 flex-col gap-2">
          <CompositionBar items={timeItems} unit="s" />
          {tokenItems.some((t) => t.value > 0) && <CompositionBar items={tokenItems} unit="tok" />}
          {loop && (
            <div className="flex items-center gap-1.5 text-[11.5px] text-role-system">
              <b className="rounded-full bg-role-assistant/10 px-1.5 text-[10.5px] text-role-assistant">
                闭环
              </b>
              声明 {loop.total} 条 · 闭环 {(loop.closed || []).length} · 未改善{" "}
              {(loop.open || []).length}
              {(loop.dismissed || []).length ? ` · 已忽略 ${(loop.dismissed || []).length}` : ""}
            </div>
          )}
        </div>

        <div className="min-w-0 border-l border-black/5 pl-3.5">
          {s.usage_turns ? (
            <div className="relative max-w-[420px]">
              <MineChart spec={{ kind: "donut", unit: "tok", items: cacheItems }} height={124} />
              <div className="pointer-events-none absolute left-[38%] top-1/2 -translate-x-1/2 -translate-y-1/2 text-center">
                <b className="block text-[22px] font-bold leading-none text-ink tabular-nums">
                  {s.cache_hit_pct}%
                </b>
                <span className="mt-0.5 block text-[11px] text-role-system">缓存命中</span>
              </div>
            </div>
          ) : (
            <div className="flex h-[124px] items-center text-[11.5px] text-role-system">
              无计费数据
            </div>
          )}
        </div>
      </div>
    </Section>
  );
}
