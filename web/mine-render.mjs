/**
 * ClipVault session-analysis (mine) display logic — the SINGLE SOURCE for the
 * 「分析」sheet HTML. Extracted verbatim from the vanilla panel
 * (trae_hooks/web/sessions-vanilla.html) so the React app renders the same
 * structure and the same semantic colours. Do NOT fork a second implementation
 * (docs/design-web-frontend.md §5, docs/design-taste.md 「分析」).
 *
 * Pure string builders: no DOM, no network, so node --test can assert on them.
 * Charts come from ./mine-charts.mjs; timestamps from ./session-render.mjs.
 *
 * Sheet structure (fixed by taste): ① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本.
 */
import {
  PHASE_COLORS,
  SEV_COLORS,
  colorAt,
  columns,
  donut,
  fmtValue,
  lineChart,
  rankBars,
  stackBar,
} from "./mine-charts.mjs";
import { localDateTime } from "./session-render.mjs";

export const escMine = (s) =>
  String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");

export const MINE_NUM_COLS = new Set([
  "n", "writes", "reads", "sec", "share", "work", "wait", "tools", "fail", "rate",
  "tokens", "loads", "avg_tokens", "total_tokens", "usd", "inp", "cr", "out", "hit", "e2e",
]);

export const MINE_PHASES = ["implement", "review", "debug", "ship", "taste"];
export const MINE_PHASE_LABEL = {
  implement: "实现",
  review: "评审",
  debug: "排查",
  ship: "提交",
  taste: "规范",
};

export const MINE_SEV = {
  high: { cls: "sev-high", label: "需处理" },
  med: { cls: "sev-med", label: "注意" },
  note: { cls: "sev-note", label: "观察" },
  good: { cls: "sev-good", label: "良好" },
};

const gradeClass = (score) =>
  score >= 85 ? "g-good" : score >= 70 ? "g-ok" : score >= 50 ? "g-warn" : "g-bad";
const phaseColor = (phase, i) => PHASE_COLORS[phase] || colorAt(i);
const sevColor = (sev) => SEV_COLORS[sev] || SEV_COLORS.note;

export const mineSpan = (v) => {
  const n = Number(v) || 0;
  if (n >= 3600) return `${(n / 3600).toFixed(1)}h`;
  if (n >= 60) return `${Math.round(n)}s`;
  return `${Math.round(n * 10) / 10}s`;
};

export const mineUsd = (v) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  return n >= 0.1 ? `$${n.toFixed(3)}` : `$${n.toFixed(4)}`;
};

export const mineMetric = (data, id) =>
  (((data || {}).metrics) || []).find((m) => m.id === id) || null;

export const mineDeltaTxt = (m) => {
  if (!m || m.delta === null || m.delta === undefined) return "";
  const d = Number(m.delta);
  if (!Number.isFinite(d) || d === 0) return "Δ0";
  return `Δ${d > 0 ? "+" : "-"}${Math.abs(d) >= 100 ? Math.round(Math.abs(d)) : Math.round(Math.abs(d) * 100) / 100}`;
};

export const mineDeltaCls = (m) => {
  if (!m || m.delta === null || m.delta === undefined) return "";
  const d = Number(m.delta);
  if (!Number.isFinite(d) || d === 0) return "";
  const worse = m.dir === "up" ? d < 0 : d > 0;
  return worse ? "up" : "down";
};

export const mineBarPct = (m) => {
  if (!m || m.target === null || m.target === undefined) return 0;
  const now = Number(m.value) || 0;
  const tgt = Number(m.target) || 0;
  if (tgt <= 0) return now > 0 ? 100 : 0;
  return Math.max(4, Math.min(100, Math.round((100 * now) / tgt)));
};

export const abbrev = (s, n = 46) => {
  const t = String(s || "");
  if (t.length <= n) return t;
  const head = Math.ceil((n - 1) / 2);
  return `${t.slice(0, head)}…${t.slice(t.length - (n - 1 - head))}`;
};

// Shape follows the data: the backend declares which chart a table wants.
const chartRows = (t) => {
  const c = (t && t.chart) || {};
  return (t.rows || []).map((r, i) => ({
    label: String(r[c.label] ?? ""),
    value: Number(r[c.value] ?? 0),
    raw: r,
    i,
  }));
};

export const renderChartFor = (t) => {
  const c = t && t.chart;
  if (!c) return "";
  const rows = chartRows(t);
  const unit = c.unit || "";
  const base = { unit, aria: t.caption || "" };
  if (c.kind === "donut") {
    const total = rows.reduce((a, r) => a + r.value, 0);
    return donut(
      rows.map((r, i) => ({
        label: MINE_PHASE_LABEL[r.label] || r.label,
        value: r.value,
        color: phaseColor(r.label, i),
      })),
      { ...base, center: fmtValue(total, unit), centerSub: t.caption || "" },
    );
  }
  if (c.kind === "stack") {
    return stackBar(rows.map((r, i) => ({ label: r.label, value: r.value, color: colorAt(i) })), base);
  }
  if (c.kind === "line") {
    return lineChart(rows.map((r) => ({ label: r.label, value: r.value })), {
      ...base,
      title: t.caption,
      color: "#2f8f83",
    });
  }
  if (c.kind === "columns") {
    return columns(
      rows.map((r) => ({
        label: MINE_PHASE_LABEL[r.label] || r.label,
        value: r.value,
        flag: Number(r.raw.fails || 0) > 0,
        jump: r.raw.index,
      })),
      { ...base, height: 52 },
    );
  }
  return rankBars(rows.map((r, i) => ({ label: r.label, value: r.value, color: colorAt(i) })), base);
};

export const renderTable = (t) => {
  if (!t || !t.rows || !t.rows.length) return "";
  const maxima = {};
  t.cols.forEach((c) => {
    if (!MINE_NUM_COLS.has(c.id)) return;
    let m = 0;
    t.rows.forEach((r) => {
      const v = Number(r[c.id]);
      if (Number.isFinite(v) && v > m) m = v;
    });
    maxima[c.id] = m;
  });
  const cap = t.caption ? `<div class="mine-cap">${escMine(t.caption)}</div>` : "";
  const chart = t.chart ? `<div class="mc-wrap">${renderChartFor(t)}</div>` : "";
  const head = t.cols.map((c) => `<th>${escMine(c.title)}</th>`).join("");
  const body = t.rows
    .map(
      (row) =>
        `<tr>${t.cols
          .map((c) => {
            const raw = row[c.id] ?? "";
            if (MINE_NUM_COLS.has(c.id)) {
              const v = Number(raw);
              const pct = Number.isFinite(v) && maxima[c.id] ? Math.max(3, Math.round((100 * v) / maxima[c.id])) : 0;
              return `<td class="num ${escMine(c.id)}"><i class="mine-bar" style="--v:${pct}%"></i><span>${escMine(raw)}</span></td>`;
            }
            return `<td class="${escMine(c.id)}">${escMine(raw)}</td>`;
          })
          .join("")}</tr>`,
    )
    .join("");
  return `${cap}${chart}<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
};

export const renderVerdict = (data) => {
  const s = data.summary || {};
  const h = s.health || {};
  const flow = s.flow || {};
  const losses = data.losses || [];
  const lossS = losses.reduce((a, l) => a + (Number(l.s) || 0), 0);
  const lossUsd = losses.reduce((a, l) => a + (Number(l.usd) || 0), 0);
  const score = Number(h.score) || 0;
  const defs = [
    ["工作秒", mineSpan(s.work_s), "work_s", "t-time"],
    ["等待秒", mineSpan(s.wait_s), "wait_s", "t-time"],
    ["可归因损耗", mineSpan(lossS), "loss_s", "t-loss"],
    ["失败调用", s.fail_n ?? 0, "fail_n", "t-loss"],
    ["额外往返", flow.extra_roundtrips ?? 0, "extra_trips", "t-loss"],
    ["费用", s.usage_turns ? mineUsd(s.cost_usd) : "—", "cost_usd", "t-money"],
    ["缓存命中", s.usage_turns ? `${s.cache_hit_pct}%` : "—", "cache_hit_pct", "t-money"],
    ["工具/回合", s.tools_per_turn ?? 0, "tools_per_turn", ""],
  ];
  const tiles = defs
    .map(([label, value, id, cls]) => {
      const m = mineMetric(data, id);
      const dTxt = mineDeltaTxt(m);
      return (
        `<div class="mine-kpi"><b class="${cls}">${escMine(value)}</b><span>${escMine(label)}</span>` +
        (dTxt ? `<em class="${mineDeltaCls(m)}">${escMine(dTxt)}</em>` : "") +
        "</div>"
      );
    })
    .join("");
  const workOk = Math.max(0, (Number(s.work_s) || 0) - (Number(s.fail_s) || 0));
  const wall = workOk + (Number(s.wait_s) || 0) + (Number(s.fail_s) || 0);
  const tOut = Number(s.tokens_out) || 0;
  const tCw = Number(s.cache_write) || 0;
  const tCr = Number(s.cache_read) || 0;
  const tokTotal = tOut + tCw + tCr;
  const timeStack = stackBar(
    [
      { label: "工作（不含失败）", value: workOk, color: "#0071e3" },
      { label: "等待", value: Number(s.wait_s) || 0, color: "rgba(60,60,67,0.38)" },
      { label: "失败", value: Number(s.fail_s) || 0, color: "#c2410c" },
    ],
    { unit: "s", aria: `时间构成 ${mineSpan(wall)}` },
  );
  const tokenStack = tokTotal
    ? stackBar(
        [
          { label: "输出", value: tOut, color: "#2f8f83" },
          { label: "写缓存", value: tCw, color: "#c47a2c" },
          { label: "缓存读", value: tCr, color: "rgba(47,143,131,0.40)" },
        ],
        { unit: "tok", aria: "tokens 构成" },
      )
    : "";
  const cache = (data.series || {}).cache || {};
  const cacheGauge = s.usage_turns
    ? donut(
        [
          { label: "缓存读", value: Number(cache.read) || 0, color: "#2f8f83" },
          { label: "未缓存输入", value: Number(cache.uncached) || 0, color: "#c47a2c" },
        ],
        { unit: "tok", center: `${s.cache_hit_pct}%`, centerSub: "缓存命中", aria: "缓存命中构成" },
      )
    : "";
  const loop = data.loop || null;
  const loopChip = loop
    ? `<div class="mine-loop"><b>闭环</b>声明 ${loop.total} 条 · 闭环 ${(loop.closed || []).length} · 未改善 ${(loop.open || []).length}` +
      `${(loop.dismissed || []).length ? ` · 已忽略 ${loop.dismissed.length}` : ""}</div>`
    : "";
  return `<section class="mine-sec" id="mineVerdict">
      <div class="mine-sec-h">损耗判定<span class="mine-count">${losses.length}</span><span class="mine-hint">可归因 ${escMine(mineSpan(lossS))}${lossUsd ? ` · ${escMine(mineUsd(lossUsd))}` : ""}</span></div>
      <div class="mine-verdict ${gradeClass(score)}">
        <div class="mine-score"><b>${escMine(h.score ?? "-")}</b><span>${escMine(h.grade || "")}</span></div>
        <div class="mine-kpis">${tiles}</div>
        <div class="mine-compose">${timeStack}${tokenStack}${loopChip}</div>
        ${cacheGauge ? `<div class="mine-cache">${cacheGauge}</div>` : ""}
      </div>
    </section>`;
};

export const renderRefs = (refs) => {
  // The same failure repeats; show it once with a count instead of six chips.
  const seen = new Map();
  (refs || []).forEach((r) => {
    if (r.turn === null || r.turn === undefined) return;
    const key = `${r.turn}|${r.label}|${r.exit_code || ""}`;
    const hit = seen.get(key);
    if (hit) hit.n += 1;
    else seen.set(key, { ref: r, n: 1 });
  });
  const values = [...seen.values()];
  const chips = values
    .slice(0, 4)
    .map(
      ({ ref: r, n }) =>
        `<button type="button" class="mine-ref" data-turn="${Number(r.turn)}" title="${escMine(`${r.label || ""} ${r.event_id || ""}`)}">#${Number(r.turn)} ${escMine(abbrev(r.label))}${r.exit_code ? ` · exit ${r.exit_code}` : ""}${n > 1 ? ` ×${n}` : ""}</button>`,
    );
  const more = values.length - chips.length;
  if (more > 0) {
    chips.push(
      `<button type="button" class="mine-ref" data-turn="${Number(values[4].ref.turn)}" title="展开该回合看全部证据">+${more} 更多（点回合看明细）</button>`,
    );
  }
  (refs || [])
    .filter((r) => r.turn === null || r.turn === undefined)
    .slice(0, 4)
    .forEach((r) => chips.push(`<span class="mine-ref">${escMine(abbrev(r.label))}</span>`));
  return chips.length ? `<div class="mine-refs">${chips.join("")}</div>` : "";
};

export const renderAck = (f) => {
  // L3 in the sheet: what the Agent/human claims it applied, and whether the
  // metric actually moved since the claim.
  const a = f.ack;
  const m = f.metric || {};
  const track =
    `<span class="mine-ack-btns"><button type="button" class="mine-ack" data-ack="${escMine(f.id)}" data-ack-status="applied">标记已应用</button>` +
    `<button type="button" class="mine-ack" data-ack="${escMine(f.id)}" data-ack-status="dismissed">忽略</button></span>`;
  if (!a) return `<div class="mine-ack-row">${track}</div>`;
  const state = a.closed === true ? "已闭环" : a.closed === false ? "未改善" : "无目标";
  const cls = a.closed === true ? "good" : a.closed === false ? "open" : "note";
  return (
    `<div class="mine-ack-row is-acked">` +
    `<span class="mine-ack-chip ${cls}">${a.status === "dismissed" ? "已忽略" : escMine(state)}</span>` +
    `<span class="mine-ack-txt">${escMine(m.id || a.metric_id || "")} ${escMine(a.at_now ?? "-")} → ${escMine(a.now ?? "-")}` +
    `${m.target !== null && m.target !== undefined ? `（目标 ${escMine(m.target)}${escMine(m.unit || "")}）` : ""}` +
    `${a.note ? ` · ${escMine(a.note)}` : ""}</span>${track}</div>`
  );
};

export const renderLosses = (data) => {
  const list = data.findings || [];
  const head =
    `<div class="mine-sec-h">损耗排行 · 按 $ / 秒<span class="mine-count">${list.length}</span>` +
    (list.some((f) => (f.impact || {}).kind === "estimated") ? `<span class="mine-hint">含估算项</span>` : "") +
    "</div>";
  if (!list.length) {
    return `<section class="mine-sec" id="mineLosses">${head}<p class="mine-empty">${data.n_rows ? "没有信号形成结论" : "还没有足够事件"}</p></section>`;
  }
  // One unit per chart, sorted descending: mixing s and $ in one axis printed
  // "$6439" for a value that was seconds. $ chart only when cost data exists.
  const byUsd = list
    .filter((f) => Number((f.impact || {}).usd) > 0)
    .sort((a, b) => Number(b.impact.usd) - Number(a.impact.usd));
  const byS = [...list].sort(
    (a, b) => Number((b.impact || {}).s || 0) - Number((a.impact || {}).s || 0),
  );
  const shapeRows = (rows, useUsd) =>
    rankBars(
      rows.map((f) => ({
        label: f.title || f.id,
        value: useUsd ? Number(f.impact.usd) : Number((f.impact || {}).s) || 0,
        sub: (f.impact || {}).kind === "estimated" ? "估算" : "实测",
        color: sevColor(f.sev),
        jump: `loss-${f.id}`,
      })),
      { unit: useUsd ? "USD" : "s", aria: useUsd ? "按 $ 损耗排序" : "按秒损耗排序" },
    );
  const shapes =
    (byUsd.length ? `<div class="mine-cap">按 $ 排序</div>${shapeRows(byUsd, true)}` : "") +
    `<div class="mine-cap">按秒排序（含墙钟空档）</div>${shapeRows(byS, false)}`;
  const cards = list
    .map((f, i) => {
      const sev = MINE_SEV[f.sev] || MINE_SEV.note;
      const imp = f.impact || {};
      const m = f.metric;
      const mm = m ? mineMetric(data, m.id) : null;
      const reached = !!(
        m &&
        m.target !== null &&
        m.target !== undefined &&
        mm &&
        mm.dir !== "up" &&
        Number(m.now) <= Number(m.target)
      );
      const metricRow = m
        ? `<div class="mine-metric${reached ? " good" : ""}"><span class="k">${escMine((mm && mm.label) || m.id)}</span>` +
          `<span class="now">${escMine(m.now ?? "—")}${escMine(m.unit || "")}</span>` +
          (m.target === null || m.target === undefined
            ? ""
            : `<span class="arrow">→</span><span class="tgt">目标 ${escMine(m.target)}${escMine(m.unit || "")}</span><span class="mine-track"><i style="--v:${mm ? mineBarPct(mm) : 0}%"></i></span>`) +
          (mm && mineDeltaTxt(mm)
            ? `<span class="delta ${mineDeltaCls(mm)}">较基线 ${escMine(mineDeltaTxt(mm))}</span>`
            : "") +
          "</div>"
        : "";
      return `<article class="mine-loss ${sev.cls}" id="loss-${escMine(f.id || i)}">
          <div class="mine-loss-h"><span class="mine-rank">${i + 1}</span><span class="mine-sev">${sev.label}</span>
            <h4>${escMine(f.title || "")}</h4>
            <span class="mine-impact"><b class="${imp.usd ? "usd" : ""}">${escMine(mineSpan(imp.s))}${imp.usd ? ` · ${escMine(mineUsd(imp.usd))}` : ""}</b>${escMine(imp.kind === "estimated" ? "估算" : "实测")}</span>
          </div>
          ${metricRow}
          <p class="mine-claim">${escMine(f.text || "")}</p>
          ${f.cause ? `<p class="mine-line"><b>原因</b>${escMine(f.cause)}</p>` : ""}
          ${f.action ? `<p class="mine-line action"><b>动作</b>${escMine(f.action)}</p>` : ""}
          ${f.gate ? `<p class="mine-line gate"><b>闸门</b>${escMine(String(f.gate).replace(/^-\s*/, ""))}</p>` : ""}
          ${(f.refs || []).length ? renderRefs(f.refs) : ""}
          ${renderAck(f)}
        </article>`;
    })
    .join("");
  return `<section class="mine-sec" id="mineLosses">${head}${shapes}${cards}</section>`;
};

export const renderTurnDetail = (data, idx) => {
  const t = (data.turns || []).find((x) => Number(x.index) === Number(idx));
  if (!t) return "";
  const chips = [
    ["工具", t.tools],
    ["失败", t.fails],
    ["重试", t.retries],
    ["工作", mineSpan(t.work_s)],
    ["等待", mineSpan(t.wait_s)],
    ["费用", t.cost_usd ? mineUsd(t.cost_usd) : "—"],
    ["输出 tok", t.tokens_out],
    ["写缓存", t.cache_write],
  ]
    .map(([k, v]) => `<span>${escMine(k)} <b>${escMine(v)}</b></span>`)
    .join("");
  const refs = [];
  (data.findings || []).forEach((f) =>
    (f.refs || []).forEach((r) => {
      if (Number(r.turn) === Number(idx)) refs.push(r);
    }),
  );
  return `<div class="mine-turn-detail" data-turn-detail="${Number(idx)}">
      <div class="kv-row">${chips}</div>
      <p class="mine-line"><b>prompt</b>${escMine(t.prompt || "")}</p>
      ${t.nudge ? `<p class="mine-line"><b>性质</b>短催回合：这一整个回合的成本计入返工损耗。</p>` : ""}
      ${refs.length ? renderRefs(refs) : ""}
    </div>`;
};

export const renderTimeline = (data, openTurn = null) => {
  const turns = data.turns || [];
  if (!turns.length) return "";
  const maxW = Math.max(1, ...turns.map((t) => Number(t.wall_s) || 0));
  const cards = turns
    .map((t) => {
      const w = Math.max(3, Math.round((100 * (Number(t.wall_s) || 0)) / maxW));
      const ph = MINE_PHASES.includes(t.phase) ? t.phase : "other";
      const open = Number(openTurn) === Number(t.index);
      const btn = `<button type="button" class="mine-turn ph-${ph}${t.fails ? " has-fail" : ""}${open ? " is-open" : ""}" data-mine-turn="${Number(t.index)}" id="turn-${Number(t.index)}">
          <span class="mine-turn-h"><b>#${Number(t.index)}</b><em>${escMine(MINE_PHASE_LABEL[t.phase] || "其他")}</em><i>${escMine(localDateTime(t.ts) || "")}</i></span>
          <span class="mine-turn-stat">${Number(t.tools)} 工具${t.fails ? ` · ${Number(t.fails)} 失败` : ""}${t.cost_usd ? ` · ${mineUsd(t.cost_usd)}` : ""} · ${escMine(mineSpan(t.wall_s))}</span>
          <span class="mine-turn-p">${escMine(t.prompt || "")}</span>
          <span class="mine-turn-bar"><i style="width:${w}%"></i></span>
        </button>`;
      return btn + (open ? renderTurnDetail(data, t.index) : "");
    })
    .join("");
  const inst = ((data.window || {}).instances || []).join("、");
  const wallChart = columns(
    turns.map((t) => ({
      label: localDateTime(t.ts) || `#${t.index}`,
      value: Number(t.wall_s) || 0,
      flag: Number(t.fails) > 0,
      jump: t.index,
      note: `${Number(t.tools)} 工具${t.fails ? ` · ${Number(t.fails)} 失败` : ""}`,
    })),
    {
      unit: "s",
      height: 52,
      title: "每回合墙钟",
      total: turns.reduce((a, t) => a + (Number(t.wall_s) || 0), 0),
      aria: "回合墙钟分布",
      axisLeft: localDateTime(turns[0].ts) || "",
      axisRight: localDateTime(turns[turns.length - 1].ts) || "",
    },
  );
  return `<section class="mine-sec" id="mineTimeline">
      <div class="mine-sec-h">回合时间轴<span class="mine-count">${turns.length}</span><span class="mine-hint">柱=墙钟（红点=该回合有失败）· 点击就地展开</span></div>
      ${inst && inst.includes("、") ? `<p class="mine-line"><b>多实例</b>窗口含 ${escMine(inst)}，按事件时间合并。</p>` : ""}
      ${wallChart}
      <div class="mine-turns">${cards}</div>
    </section>`;
};

export const renderLedger = (data) => {
  const active = data.active || null;
  const blocks = Object.entries(data.blocks || {}).filter(([id]) => !active || active.includes(id));
  if (!blocks.length) return "";
  const secs = blocks
    .map(([id, b]) => {
      const tables = (b.tables && b.tables.length ? b.tables : b.table ? [b.table] : [])
        .map(renderTable)
        .join("");
      if (!tables) return "";
      const axis = b.axis === "user" ? "user" : "agent";
      return `<section class="mine-blk axis-${axis}" id="blk-${escMine(id)}">
          <div class="mine-blk-h"><span class="axis">${axis === "user" ? "用户" : "Agent"}</span><h3>${escMine(b.title || id)}</h3></div>
          ${b.note ? `<p class="note">${escMine(b.note)}</p>` : ""}
          ${tables}
        </section>`;
    })
    .join("");
  return `<section class="mine-sec" id="mineLedger">
      <div class="mine-sec-h">账本 · 事实<span class="mine-count">${blocks.length}</span><span class="mine-hint">始终展开</span></div>${secs}
    </section>`;
};

export const renderNav = (data) => {
  // Jump bar only: the direction chips in the head are the *filter*, and
  // duplicating them here made the hierarchy unreadable.
  const chips = [`<button type="button" data-jump="mineLosses">损耗 ${(data.findings || []).length}</button>`];
  if ((data.turns || []).length) chips.push(`<button type="button" data-jump="mineTimeline">回合 ${(data.turns || []).length}</button>`);
  chips.push(`<button type="button" data-jump="mineLedger">账本 ${Object.keys(data.blocks || {}).length}</button>`);
  return `<nav class="mine-nav">${chips.join("")}</nav>`;
};

/** ④ sections body: ① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本. */
export const mineBodyHtml = (data, { openTurn = null } = {}) =>
  renderNav(data) + renderVerdict(data) + renderLosses(data) + renderTimeline(data, openTurn) + renderLedger(data);

/** Header summary line (window + counts + flags). */
export const mineSummaryHtml = (data) => {
  if (!data || !data.ok) return "";
  const w = data.window || {};
  const s = data.summary || {};
  return (
    `${escMine(localDateTime(w.from) || w.from || "?")} → ${escMine(localDateTime(w.to) || w.to || "?")}` +
    ` · ${s.n_turns || 0} 回合 · ${s.n_tools || 0} 工具` +
    (w.instances && w.instances.length ? ` · ${escMine(w.instances.join("/"))}` : "") +
    (w.truncated ? `<span class="mine-flag warn">12000 行截断</span>` : "") +
    (data.baseline && data.baseline.source ? `<span class="mine-flag base">对照 ${escMine(data.baseline.source)}</span>` : "") +
    (s.usage_turns ? "" : `<span class="mine-flag est">无计费数据</span>`)
  );
};

/** Direction filter chips (head). `selected` empty means "all on". */
export const mineDirectionsHtml = (directions, selected = []) =>
  (directions || [])
    .map((d) => {
      const on = !selected.length || selected.includes(d.id);
      return `<button type="button" class="mine-chip${on ? " is-on" : ""}" data-dir="${escMine(d.id)}">${escMine(d.title)}</button>`;
    })
    .join("");

/** AGENTS 草稿: the copy payload behind 「复制 AGENTS 草稿」. */
export const mineDraftMarkdown = (data) => {
  const found = (data && (data.findings || data.feedback)) || [];
  const ruled = found.filter((f) => f.draft);
  const win = (data && data.window) || {};
  return [
    `# 从会话分析得到的约束（${(data && data.scope) || "session"} · ${win.from || ""} → ${win.to || ""}）`,
    "",
    ...(ruled.length
      ? ruled.map((f, i) => {
          const imp = f.impact || {};
          const cost = [imp.s ? `${imp.s}s` : "", imp.usd ? `$${imp.usd}` : ""].filter(Boolean).join(" / ");
          return [
            `## ${i + 1}. ${f.title}${cost ? `（${cost}，${imp.kind === "estimated" ? "估算" : "实测"}）` : ""}`,
            f.draft,
            "",
          ].join("\n");
        })
      : found.map((f) => `- ${f.text || f.title}`)),
    "",
    "<!-- 复测：同一窗口重跑会话分析，指标应向 target 移动 -->",
    "",
  ].join("\n");
};

/** Auto-refresh must not repaint identical content (drops scroll / open turn). */
export const mineDataSig = (data) => {
  if (!data || !data.ok) return `err:${(data && data.error) || ""}`;
  const s = data.summary || {};
  return JSON.stringify([
    data.scope, s.n_rows, s.n_turns, s.n_tools, s.work_s, s.wait_s, s.fail_n, s.idle_s, s.cost_usd,
    (data.losses || []).map((l) => `${l.id}:${l.s}:${l.usd}`),
    (data.findings || []).map(
      (f) =>
        `${f.id}:${f.sev}:${(f.impact || {}).s}:${(f.impact || {}).usd}` +
        (f.ack ? `:ack=${f.ack.status}:${f.ack.moved}` : ""),
    ),
    data.loop ? JSON.stringify(data.loop) : "",
    (data.turns || []).length,
    (data.metrics || []).map((m) => `${m.id}=${m.value}${m.delta === null || m.delta === undefined ? "" : `d${m.delta}`}`),
    (data.baseline || {}).source || "",
    data.active,
  ]);
};
