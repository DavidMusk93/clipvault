// ECharts is loaded on demand (code-split). Only the pieces we use are
// registered, so the analysis route does not add ~1 MB to first paint.
let ready: Promise<typeof import("echarts/core")> | null = null;

export function loadECharts() {
  if (!ready) {
    ready = (async () => {
      const echarts = await import("echarts/core");
      const { BarChart, LineChart, PieChart } = await import("echarts/charts");
      const { GridComponent, TooltipComponent, LegendComponent } = await import(
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
        CanvasRenderer,
      ]);
      return echarts;
    })();
  }
  return ready;
}

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
          label: { fontSize: 10, color: "#1d1d1f" },
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
