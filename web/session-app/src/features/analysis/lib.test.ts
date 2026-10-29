import { describe, expect, it } from "vitest";
import type { Mine } from "../../api/mine";
import {
  ledgerChart,
  lossParts,
  metricText,
  phaseTotals,
  turnBars,
  turnReadout,
  verdictHeadline,
  windowText,
} from "./lib";

// Real shape from /api/mine?scope=recent (mac-work, 2026-10-29): idle dwarfs
// every tool-time loss by ~600×.
const recent = {
  ok: true,
  scope: "recent",
  summary: { n_turns: 25, n_tools: 922, health: { score: 76, grade: "尚可" } },
  losses: [
    { id: "fail_retry", label: "失败与重试", s: 457.4, usd: 0.2308, kind: "measured" },
    { id: "rework", label: "返工往返", s: 617.4, usd: 0.1054, kind: "measured" },
    { id: "idle", label: "长时间空档", s: 269404.7, usd: 0, kind: "measured" },
    { id: "reread", label: "重复读", s: 462.1, usd: 0, kind: "measured" },
    { id: "locate", label: "缺定位线索", s: 365.3, usd: 0, kind: "measured" },
  ],
} as unknown as Mine;

describe("verdict readings", () => {
  it("keeps idle off the shared loss axis and says so", () => {
    const lp = lossParts(recent);
    expect(lp.parts.map((p) => p.id)).toEqual(["rework", "reread", "fail_retry", "locate"]);
    expect(lp.idle?.s).toBe(269404.7);
    expect(Math.round(lp.totalS)).toBe(1902);
    expect(lp.totalUsd).toBeCloseTo(0.3362, 4);
    // one hue, stepped by rank
    expect(lp.parts[0].color).toBe("rgba(194,65,12,1)");
    expect(lp.parts[3].color).toBe("rgba(194,65,12,0.36)");

    const v = verdictHeadline(recent);
    expect(v.title).toBe("可归因损耗 1902s · $0.336");
    expect(v.detail).toBe("最大一项 返工往返 617s · 25 回合 · 922 工具");
    expect(v.idle).toMatch(/^另有长空档 74\.8h/);
    expect(v.tone).toBe("ok");
  });

  it("no losses reads as such, not as zero seconds", () => {
    const v = verdictHeadline({ ok: true, scope: "session", losses: [] } as unknown as Mine);
    expect(v.title).toBe("没有可归因的损耗");
    expect(v.score).toBeNull();
  });

  it("window is local minutes, never raw UTC microseconds", () => {
    const w = windowText({ from: "2026-10-29 08:12:22.419403", to: "2026-10-29 09:57:31.18" });
    expect(w).not.toMatch(/\.\d{3}/);
    expect(w).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}–\d{2}:\d{2}$/);
    expect(windowText({ from: "2026-10-26 03:04:06", to: "2026-10-29 10:01:52" })).toMatch(
      /^\d{2}-\d{2} \d{2}:\d{2} – \d{2}-\d{2} \d{2}:\d{2}$/,
    );
    expect(windowText({})).toBe("");
  });

  it("metric text follows the unit", () => {
    expect(metricText({ value: 4757.6, unit: "s" })).toBe("1.3h");
    expect(metricText({ value: 7.4, unit: "%" })).toBe("7.4%");
    expect(metricText({ value: 2.87, unit: "次" })).toBe("2.87");
    expect(metricText({ value: null, unit: "" })).toBe("—");
  });
});

describe("turn strip", () => {
  const turns = [
    { index: 1, phase: "implement", ts: "2026-10-29 08:12:22", wall_s: 487.3, tools: 80, fails: 0 },
    { index: 2, phase: "other", ts: "2026-10-29 08:32:38", wall_s: 60.8, tools: 14, fails: 0 },
    {
      index: 3,
      phase: "debug",
      ts: "2026-10-29 08:36:09",
      wall_s: 86.2,
      tools: 15,
      fails: 1,
      cost_usd: 0.0123,
    },
  ];
  it("height is wall clock on one scale, failures flagged, phase coloured", () => {
    const bars = turnBars(turns);
    expect(bars.map((b) => b.pct)).toEqual([100, 12, 18]);
    expect(bars.map((b) => b.fail)).toEqual([false, false, true]);
    expect(bars[0].color).toBe("#c47a2c");
  });
  it("phase legend sums wall clock by phase, largest first", () => {
    expect(phaseTotals(turns).map((p) => [p.label, Math.round(p.s)])).toEqual([
      ["实现", 487],
      ["排查", 86],
      ["其他", 61],
    ]);
  });
  it("readout names the turn with its numbers", () => {
    expect(turnReadout(turns[2])).toMatch(
      /^#3 · 排查 · \d{2}:\d{2} · 86s · 15 工具 · 1 失败 · \$0\.0123$/,
    );
  });
});

describe("ledger chart policy", () => {
  it("drops charts that only repeat the table", () => {
    // bars of a column the table already bars in-cell
    expect(
      ledgerChart(
        "bars",
        Array.from({ length: 10 }, (_, i) => ({ value: 10 - i })),
      ),
    ).toBeNull();
    // a single-part ring is a filled circle
    expect(ledgerChart("bars", [{ value: 716 }])).toBeNull();
    // few parts → ring is a real part-to-whole reading
    expect(ledgerChart("bars", [{ value: 6 }, { value: 4 }, { value: 2 }])).toBe("donut");
    expect(ledgerChart("columns", [{ value: 1 }, { value: 2 }, { value: 3 }])).toBe("columns");
    expect(ledgerChart("line", [{ value: 1 }, { value: 2 }, { value: 3 }, { value: 4 }])).toBe(
      "line",
    );
  });
});
