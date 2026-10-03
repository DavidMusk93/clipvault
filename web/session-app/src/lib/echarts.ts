// ECharts is loaded on demand (code-split). Only the pieces we use are
// registered, so the analysis route does not add ~1 MB to first paint.
let ready: Promise<typeof import("echarts/core")> | null = null;

export function loadECharts() {
  if (!ready) {
    ready = (async () => {
      const echarts = await import("echarts/core");
      const { BarChart, LineChart, PieChart } = await import("echarts/charts");
      const {
        GridComponent,
        LegendComponent,
        MarkPointComponent,
        TitleComponent,
        TooltipComponent,
      } = await import("echarts/components");
      const { CanvasRenderer } = await import("echarts/renderers");
      echarts.use([
        BarChart,
        LineChart,
        PieChart,
        GridComponent,
        TooltipComponent,
        LegendComponent,
        TitleComponent,
        MarkPointComponent,
        CanvasRenderer,
      ]);
      return echarts;
    })();
  }
  return ready;
}

// ---------------------------------------------------------------------------
// Session-analysis charts. The shared renderer (web/mine-render.mjs) decides
// WHICH chart, which unit and which semantic colour (the taste); this module
// only turns that spec into an ECharts option, themed with the same tokens as
// `theme/panel.css`. docs/design-web-frontend.md §5.
// ---------------------------------------------------------------------------

export type MineChartItem = {
  label: string;
  value: number;
  color: string;
  flag?: boolean;
  jump?: number | string | null;
  sub?: string;
  note?: string;
};

export type MineChartSpec = {
  kind: "stack" | "donut" | "bars" | "columns" | "line";
  unit: string;
  items: MineChartItem[];
  center?: string;
  centerSub?: string;
  title?: string;
  total?: number | null;
  axisLeft?: string;
  axisRight?: string;
};

const FONT =
  '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", system-ui, sans-serif';
const INK = "#1d1d1f";
const MUTED = "#6e6e73";
const SURFACE = "#fafafa";
const LOSS = "#c2410c";

const fmt = (v: number, unit: string): string => {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  if (unit === "USD") return n >= 0.1 ? `$${n.toFixed(3)}` : `$${n.toFixed(4)}`;
  if (unit === "%") return `${Math.round(n * 10) / 10}%`;
  if (unit === "s") {
    if (Math.abs(n) >= 3600) return `${(n / 3600).toFixed(1)}h`;
    return `${Number.isInteger(n) ? n : Math.round(n * 10) / 10}s`;
  }
  if (unit === "tok") {
    if (Math.abs(n) >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}Mtok`;
    if (Math.abs(n) >= 1000) return `${(n / 1000).toFixed(1)}ktok`;
    return `${Math.round(n)}tok`;
  }
  const t = Number.isInteger(n) ? String(n) : String(Math.round(n * 10) / 10);
  return unit ? `${t}${unit}` : t;
};

const pctOf = (v: number, total: number) => (total > 0 ? (100 * v) / total : 0);

const legendText = { fontSize: 11, color: MUTED, fontFamily: FONT };
const axisText = { fontSize: 10.5, color: MUTED, fontFamily: FONT };

export function buildMineOption(spec: MineChartSpec) {
  const { items, unit } = spec;
  const total = spec.total ?? items.reduce((a, it) => a + it.value, 0);
  const base = { textStyle: { fontFamily: FONT, color: INK } };

  if (spec.kind === "donut") {
    return {
      ...base,
      tooltip: {
        trigger: "item",
        formatter: (p: { name: string; value: number }) =>
          `${p.name}<br/>${fmt(p.value, unit)} · ${pctOf(p.value, total).toFixed(1)}%`,
      },
      // No ECharts title: the centre number is an HTML overlay (mine-charts echart).
      legend: {
        orient: "vertical",
        right: 12,
        top: "middle",
        icon: "circle",
        itemWidth: 8,
        itemHeight: 8,
        itemGap: 10,
        textStyle: legendText,
        formatter: (name: string) => {
          const it = items.find((x) => x.label === name);
          return it ? `${name}  ${fmt(it.value, unit)}` : name;
        },
      },
      series: [
        {
          type: "pie",
          radius: ["56%", "84%"],
          center: ["38%", "50%"],
          avoidLabelOverlap: true,
          label: { show: false },
          labelLine: { show: false },
          emphasis: { scale: true, scaleSize: 4 },
          itemStyle: { borderColor: SURFACE, borderWidth: 2 },
          data: items.map((it) => ({
            name: it.label,
            value: it.value,
            itemStyle: { color: it.color },
          })),
        },
      ],
    };
  }

  if (spec.kind === "stack") {
    return {
      ...base,
      tooltip: {
        trigger: "item",
        formatter: (p: { seriesName: string; value: number }) =>
          `${p.seriesName}<br/>${fmt(p.value, unit)} · ${pctOf(p.value, total).toFixed(1)}%`,
      },
      // Bar only: the legend is HTML below the canvas (mine-charts echart).
      grid: { left: 0, right: 0, top: 0, bottom: 0, containLabel: false },
      xAxis: { type: "value", max: total, show: false },
      yAxis: { type: "category", data: [""], show: false },
      legend: { show: false },
      series: items.map((it) => ({
        type: "bar",
        name: it.label,
        stack: "s",
        barWidth: 16,
        itemStyle: { color: it.color, borderColor: SURFACE, borderWidth: 2, borderRadius: 8 },
        emphasis: { focus: "series" },
        data: [it.value],
      })),
    };
  }

  if (spec.kind === "bars") {
    const max = Math.max(...items.map((it) => it.value), 1);
    return {
      ...base,
      tooltip: {
        trigger: "item",
        formatter: (p: { dataIndex: number }) => {
          const it = items[p.dataIndex];
          return it ? `${it.label}<br/>${fmt(it.value, unit)}${it.sub ? ` · ${it.sub}` : ""}` : "";
        },
      },
      grid: { left: 0, right: 74, top: 4, bottom: 4, containLabel: true },
      xAxis: { type: "value", max, show: false },
      yAxis: {
        type: "category",
        inverse: true,
        data: items.map((it) => it.label),
        axisLine: { show: false },
        axisTick: { show: false },
        axisLabel: {
          fontSize: 11,
          color: INK,
          fontFamily: FONT,
          width: 230,
          overflow: "truncate",
        },
      },
      series: [
        {
          type: "bar",
          barWidth: 10,
          itemStyle: { borderRadius: 5 },
          label: {
            show: true,
            position: "right",
            fontSize: 11,
            color: MUTED,
            fontFamily: FONT,
            formatter: (p: { value: number }) => fmt(p.value, unit),
          },
          data: items.map((it) => ({ value: it.value, itemStyle: { color: it.color } })),
        },
      ],
    };
  }

  if (spec.kind === "columns") {
    return {
      ...base,
      tooltip: {
        trigger: "axis",
        axisPointer: { type: "shadow" },
        formatter: (ps: { dataIndex: number }[]) => {
          const it = items[ps[0]?.dataIndex ?? -1];
          return it
            ? `${it.label}<br/>${fmt(it.value, unit)}${it.note ? ` · ${it.note}` : ""}`
            : "";
        },
      },
      grid: { left: 0, right: 0, top: 8, bottom: 0, containLabel: false },
      xAxis: { type: "category", data: items.map((it) => it.label), show: false },
      yAxis: { type: "value", show: false },
      series: [
        {
          type: "bar",
          barWidth: "66%",
          itemStyle: { borderRadius: [3, 3, 0, 0] },
          data: items.map((it) => ({ value: it.value, itemStyle: { color: it.color } })),
          markPoint: {
            symbol: "circle",
            symbolSize: 6,
            itemStyle: { color: LOSS },
            label: { show: false },
            data: items.map((it, i) => (it.flag ? { coord: [i, it.value] } : null)).filter(Boolean),
          },
        },
      ],
    };
  }

  // line
  const color = items[0]?.color || "#2f8f83";
  return {
    ...base,
    tooltip: {
      trigger: "axis",
      formatter: (ps: { dataIndex: number }[]) => {
        const it = items[ps[0]?.dataIndex ?? -1];
        return it ? `${it.label}<br/>${fmt(it.value, unit)}` : "";
      },
    },
    grid: { left: 0, right: 4, top: 8, bottom: 0, containLabel: true },
    xAxis: {
      type: "category",
      data: items.map((it) => it.label),
      axisLabel: { show: false },
      axisTick: { show: false },
      axisLine: { show: false },
    },
    yAxis: {
      type: "value",
      axisLabel: axisText,
      splitLine: { lineStyle: { color: "rgba(60,60,67,0.10)" } },
    },
    series: [
      {
        type: "line",
        smooth: true,
        symbolSize: 4,
        data: items.map((it) => it.value),
        lineStyle: { width: 2, color },
        itemStyle: { color },
        areaStyle: { opacity: 0.12, color },
      },
    ],
  };
}

type EChartsInstance = {
  setOption: (o: unknown) => void;
  on: (event: string, handler: (p: { dataIndex?: number }) => void) => void;
  resize: () => void;
  dispose: () => void;
};

/** Mount every `.mc-echart` inside `root`; returns a disposer. */
export async function mountMineCharts(
  root: HTMLElement,
  onJump: (jump: number | string) => void,
): Promise<() => void> {
  const nodes = [...root.querySelectorAll<HTMLElement>(".mc-echart")];
  if (!nodes.length) return () => {};
  const echarts = await loadECharts();
  const insts: EChartsInstance[] = [];
  for (const node of nodes) {
    const raw = node.dataset.mc;
    if (!raw) continue;
    let spec: MineChartSpec;
    try {
      spec = JSON.parse(raw) as MineChartSpec;
    } catch {
      continue;
    }
    const inst = echarts.init(node) as unknown as EChartsInstance;
    inst.setOption(buildMineOption(spec));
    inst.on("click", (p) => {
      const it = spec.items[p.dataIndex ?? -1];
      if (it && it.jump != null) onJump(it.jump);
    });
    insts.push(inst);
  }
  const onResize = () => {
    for (const i of insts) i.resize();
  };
  window.addEventListener("resize", onResize);
  return () => {
    window.removeEventListener("resize", onResize);
    for (const i of insts) i.dispose();
  };
}

// Kept for the generic Chart wrapper (unused by the sheet now, still typed).
export type ChartSpec = { kind: string; label: string; value: string; unit?: string };

export function buildOption(spec: ChartSpec, rows: Record<string, unknown>[]) {
  const labels = rows.map((r) => String(r[spec.label] ?? ""));
  const values = rows.map((r) => Number(r[spec.value] ?? 0));
  const unit = spec.unit ?? "";
  const axisLabel = { color: "#8e8e93", fontSize: 10 };
  if (spec.kind === "donut" || spec.kind === "stack") {
    return {
      tooltip: { trigger: "item" },
      series: [
        {
          type: "pie",
          radius: spec.kind === "donut" ? ["42%", "70%"] : ["0%", "70%"],
          label: { fontSize: 10, color: INK },
          data: labels.map((name, i) => ({ name, value: values[i] })),
        },
      ],
    };
  }
  if (spec.kind === "line") {
    return {
      tooltip: { trigger: "axis" },
      grid: { left: 4, right: 8, top: 12, bottom: 4, containLabel: true },
      xAxis: { type: "category", data: labels, axisLabel },
      yAxis: { type: "value", name: unit, axisLabel, nameTextStyle: axisLabel },
      series: [{ type: "line", smooth: true, areaStyle: { opacity: 0.12 }, data: values }],
    };
  }
  const horizontal = spec.kind === "bars";
  return {
    tooltip: { trigger: "axis" },
    grid: { left: 4, right: 8, top: 12, bottom: 4, containLabel: true },
    xAxis: horizontal
      ? { type: "value", name: unit, axisLabel, nameTextStyle: axisLabel }
      : { type: "category", data: labels, axisLabel },
    yAxis: horizontal
      ? { type: "category", data: labels, axisLabel }
      : { type: "value", name: unit, axisLabel, nameTextStyle: axisLabel },
    series: [{ type: "bar", data: values, itemStyle: { color: "#c47a2c", borderRadius: 3 } }],
  };
}
