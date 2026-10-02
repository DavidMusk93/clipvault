import { useEffect, useRef } from "react";
import { buildOption, type ChartSpec, loadECharts } from "../../lib/echarts";

export function Chart({ spec, rows }: { spec: ChartSpec; rows: Record<string, unknown>[] }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let disposed = false;
    let instance: { resize: () => void; dispose: () => void } | null = null;
    const onResize = () => instance?.resize();

    (async () => {
      const echarts = await loadECharts();
      if (disposed || !ref.current) return;
      const inst = echarts.init(ref.current);
      inst.setOption(buildOption(spec, rows));
      instance = inst as unknown as { resize: () => void; dispose: () => void };
      window.addEventListener("resize", onResize);
    })();

    return () => {
      disposed = true;
      window.removeEventListener("resize", onResize);
      instance?.dispose();
    };
  }, [spec, rows]);

  return <div ref={ref} className="h-[180px] w-full" />;
}
