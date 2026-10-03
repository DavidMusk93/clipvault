import { fmtValue } from "@charts";

// ECharts is loaded on demand (code-split). Only the pieces we use are
// registered, so the analysis route does not add ~1 MB to first paint.
let ready: Promise<typeof import("echarts/core")> | null = null;

export function loadECharts() {
  if (!ready) {
    ready = (async () => {
      const echarts = await import("echarts/core");
      const { BarChart, LineChart, PieChart } = await import("echarts/charts");
      const { GridComponent, LegendComponent, MarkPointComponent, TooltipComponent } = await import(
        "echarts/components"
      );
      const { CanvasRenderer } = await import("echarts/renderers");
      echarts.use([
        BarChart,
        LineChart,
        PieChart,
        GridComponent,
        TooltipComponent,
        LegendComponent,
        MarkPointComponent,
        CanvasRenderer,
      ]);
      return echarts;
    })();
  }
  return ready;
}

// ---------------------------------------------------------------------------
// Session-analysis charts. The sheet decides WHICH chart, which unit and which
// semantic colour (the taste); this turns that spec into an ECharts option,
// themed with the same tokens as `theme/tokens.css`.
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
};

const FONT =
  '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", system-ui, sans-serif';
const INK = "#1d1d1f";
const MUTED = "#6e6e73";
const SURFACE = "#fafafa";
const LOSS = "#c2410c";

const fmt = (v: number, unit: string) => fmtValue(v, unit);
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
