import { useEffect, useRef } from "react";
import { cn } from "../../lib/cn";
import {
  buildMineOption,
  loadECharts,
  type MineChartItem,
  type MineChartSpec,
} from "../../lib/echarts";
import { fmtValue, pct } from "./lib";

type Inst = {
  setOption: (o: unknown, opts?: unknown) => void;
  on: (event: string, handler: (p: { dataIndex?: number }) => void) => void;
  resize: () => void;
  dispose: () => void;
};

/**
 * One ECharts instance, keyed by spec. React owns the lifecycle; a spec change
 * updates only this chart (incremental). Clicking a datum with `jump` calls
 * `onJump` — the sheet decides what that means (turn vs loss card).
 */
export function MineChart({
  spec,
  height,
  onJump,
  className,
}: {
  spec: MineChartSpec;
  height: number;
  onJump?: (jump: number | string) => void;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const inst = useRef<Inst | null>(null);
  const specRef = useRef(spec);
  specRef.current = spec;
  const onJumpRef = useRef(onJump);
  onJumpRef.current = onJump;
  // Skip redundant setOption: a parent re-render (turn toggle, refresh) creates a
  // new spec object even when the data did not change.
  const specKey = JSON.stringify(spec);
  const keyRef = useRef(specKey);

  useEffect(() => {
    let cancelled = false;
    let ro: ResizeObserver | null = null;
    void loadECharts().then((echarts) => {
      if (cancelled || !ref.current) return;
      const chart = echarts.init(ref.current) as unknown as Inst;
      inst.current = chart;
      chart.on("click", (p) => {
        const it = specRef.current.items[p.dataIndex ?? -1];
        if (it?.jump != null) onJumpRef.current?.(it.jump);
      });
      chart.setOption(buildMineOption(specRef.current), { notMerge: true });
      ro = new ResizeObserver(() => chart.resize());
      if (ref.current) ro.observe(ref.current);
    });
    return () => {
      cancelled = true;
      ro?.disconnect();
      inst.current?.dispose();
      inst.current = null;
    };
  }, []);

  useEffect(() => {
    if (keyRef.current === specKey) return;
    keyRef.current = specKey;
    inst.current?.setOption(buildMineOption(spec), { notMerge: true });
  }, [specKey, spec]);

  return <div ref={ref} className={cn("w-full", className)} style={{ height }} />;
}

/**
 * Composition bar: the segmented bar (ECharts) plus an HTML legend, so the
 * legend wraps instead of running under the bar. Taste: every segment carries
 * its number.
 */
export function CompositionBar({
  items,
  unit = "",
  className,
}: {
  items: MineChartItem[];
  unit?: string;
  className?: string;
}) {
  const shown = items.filter((it) => it.value > 0);
  if (!shown.length)
    return <div className={cn("text-[11.5px] text-role-system", className)}>无数据</div>;
  const total = shown.reduce((a, it) => a + it.value, 0);
  return (
    <div className={cn("flex flex-col gap-2", className)}>
      <MineChart spec={{ kind: "stack", unit, items: shown, total }} height={18} />
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-role-system">
        {shown.map((it) => (
          <span key={it.label} className="inline-flex items-center gap-1.5">
            <i className="size-2.5 shrink-0 rounded-[3px]" style={{ background: it.color }} />
            {it.label}
            <b className="font-semibold text-ink tabular-nums">{fmtValue(it.value, unit)}</b>
            <em className="not-italic tabular-nums">{pct(it.value, total).toFixed(1)}%</em>
          </span>
        ))}
      </div>
    </div>
  );
}
