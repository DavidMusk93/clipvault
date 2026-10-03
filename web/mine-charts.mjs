/**
 * Session-analysis charts.
 *
 * Contract: shape follows the data, never decoration.
 *   part-to-whole (few parts, need exact split) -> stackBar
 *   part-to-whole, <=6 slices, want the whole   -> donut
 *   single ratio vs target                      -> donut (ring gauge)
 *   trend over ordered points (>=3)             -> lineChart
 *   ordered many points, shape matters          -> columns
 *   ranked comparison (magnitude, few rows)     -> rankBars
 * Rule: never a pie for >6 slices, never a line for <3 points, and every chart
 * carries its numbers as text so colour is an extra channel, not the only one.
 *
 * Pure string builders: no DOM, no deps, so node --test can assert on them.
 */

const esc = (s) =>
  String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

export const CHART_PALETTE = [
  "#0071e3", // accent blue
  "#2f8f83", // teal (money / cache)
  "#c47a2c", // honey
  "#6e56cf", // violet
  "#c2410c", // loss red
  "#2e7d32", // good green
  "#1565c0", // deep blue
  "#8e8e93", // neutral
];

export const PHASE_COLORS = {
  implement: "#c47a2c",
  review: "#6e56cf",
  debug: "#c62828",
  ship: "#2e7d32",
  taste: "#1565c0",
  other: "#8e8e93",
};

export const SEV_COLORS = {
  high: "#c2410c",
  med: "#c47a2c",
  note: "#8e8e93",
  good: "#2e7d32",
};

export const colorAt = (i) => CHART_PALETTE[Math.abs(Number(i) || 0) % CHART_PALETTE.length];

export const fmtCompact = (v, digits = 0) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  if (abs >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (abs >= 10_000) return `${(n / 1000).toFixed(1)}k`;
  if (abs >= 1000) return `${(n / 1000).toFixed(2)}k`;
  return abs >= 10 || digits === 0 ? String(Math.round(n)) : n.toFixed(digits);
};

export const fmtValue = (v, unit = "", digits = 0) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  if (unit === "USD") return n >= 0.1 ? `$${n.toFixed(3)}` : `$${n.toFixed(4)}`;
  if (unit === "%") return `${Math.round(n * 10) / 10}%`;
  if (unit === "s") {
    // Match the sheet's 时间口径: seconds below an hour, hours above. No "6.44ks".
    if (Math.abs(n) >= 3600) return `${(n / 3600).toFixed(1)}h`;
    const txt = Number.isInteger(n) ? String(n) : fmtCompact(n, digits);
    return `${txt}s`;
  }
  if (unit === "tok") return `${fmtCompact(n)}tok`;
  const txt = Number.isInteger(n) ? String(n) : fmtCompact(n, digits);
  return unit ? `${txt}${unit}` : txt;
};

const pct = (part, whole) => (Number(whole) > 0 ? (100 * Number(part)) / Number(whole) : 0);

/**
 * Segmented part-to-whole bar. Segments are separated by real gaps plus a
 * hairline stroke: adjacent ratios used to visually merge into one blob.
 */
export function stackBar(parts, opts = {}) {
  const items = (parts || []).filter((p) => Number(p.value) > 0);
  const total = Number(opts.total) || items.reduce((a, p) => a + (Number(p.value) || 0), 0);
  if (!items.length || total <= 0) return `<div class="mc-empty">${esc(opts.empty || "无数据")}</div>`;
  const segs = items
    .map((p, i) => {
      const w = Math.max(1.2, pct(p.value, total));
      const color = p.color || colorAt(i);
      return (
        `<i class="mc-seg" style="flex:0 0 ${w.toFixed(3)}%;background:${color}" ` +
        `title="${esc(`${p.label} ${fmtValue(p.value, opts.unit)} · ${pct(p.value, total).toFixed(1)}%`)}"></i>`
      );
    })
    .join("");
  const legend = items
    .map((p, i) => {
      const color = p.color || colorAt(i);
      return (
        `<span class="mc-lg"><i style="background:${color}"></i>${esc(p.label)}` +
        `<b>${esc(fmtValue(p.value, opts.unit))}</b><em>${pct(p.value, total).toFixed(1)}%</em></span>`
      );
    })
    .join("");
  return (
    `<div class="mc-stack" role="img" aria-label="${esc(opts.aria || "构成")}">` +
    `<div class="mc-stack-track">${segs}</div>` +
    `<div class="mc-legend">${legend}</div></div>`
  );
}

/** Ring gauge for a single ratio (cache hit, target attainment). */
export function donut(slices, opts = {}) {
  const items = (slices || []).filter((s) => Number(s.value) > 0);
  const total = Number(opts.total) || items.reduce((a, s) => a + (Number(s.value) || 0), 0);
  const size = Number(opts.size) || 108;
  const thick = Number(opts.thickness) || 13;
  const r = (size - thick) / 2;
  const c = 2 * Math.PI * r;
  const gap = items.length > 1 ? 2.4 : 0; // px of circumference, keeps slices apart
  let offset = 0;
  const rings = (!items.length || total <= 0)
    ? `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(60,60,67,0.14)" stroke-width="${thick}"></circle>`
    : items
        .map((s, i) => {
          const len = Math.max(0.8, (c * (Number(s.value) || 0)) / total - gap);
          const color = s.color || colorAt(i);
          const seg =
            `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" ` +
            `stroke-width="${thick}" stroke-linecap="butt" ` +
            `stroke-dasharray="${len.toFixed(2)} ${(c - len).toFixed(2)}" ` +
            `stroke-dashoffset="${(-offset).toFixed(2)}" ` +
            `transform="rotate(-90 ${size / 2} ${size / 2})">` +
            `<title>${esc(`${s.label} ${fmtValue(s.value, opts.unit)} · ${pct(s.value, total).toFixed(1)}%`)}</title></circle>`;
          offset += (c * (Number(s.value) || 0)) / total;
          return seg;
        })
        .join("");
  const center = opts.center
    ? `<text x="${size / 2}" y="${size / 2 - 1}" text-anchor="middle" dominant-baseline="middle" class="mc-donut-v">${esc(opts.center)}</text>` +
      (opts.centerSub
        ? `<text x="${size / 2}" y="${size / 2 + 15}" text-anchor="middle" class="mc-donut-s">${esc(opts.centerSub)}</text>`
        : "")
    : "";
  const legend = items
    .map((s, i) => {
      const color = s.color || colorAt(i);
      return `<span class="mc-lg"><i style="background:${color}"></i>${esc(s.label)}<b>${esc(fmtValue(s.value, opts.unit))}</b><em>${pct(s.value, total).toFixed(1)}%</em></span>`;
    })
    .join("");
  return (
    `<div class="mc-donut" role="img" aria-label="${esc(opts.aria || "占比")}">` +
    `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">${rings}${center}</svg>` +
    `<div class="mc-legend mc-legend-col">${legend}</div></div>`
  );
}

/** Ranked horizontal bars: compare magnitudes and keep the exact number. */
export function rankBars(rows, opts = {}) {
  const items = (rows || []).filter((r) => r && r.label !== "");
  if (!items.length) return `<div class="mc-empty">${esc(opts.empty || "无数据")}</div>`;
  const max = Number(opts.max) || Math.max(...items.map((r) => Number(r.value) || 0), 1);
  const body = items
    .map((r, i) => {
      const v = Number(r.value) || 0;
      const w = Math.max(1, Math.min(100, (100 * v) / max));
      const color = r.color || colorAt(i);
      const jump = r.jump ? ` data-jump="${esc(r.jump)}"` : "";
      const tag = r.jump ? "button" : "div";
      const attr = r.jump ? ' type="button"' : "";
      return (
        `<${tag}${attr} class="mc-bar-row"${jump} title="${esc(`${r.label} ${fmtValue(v, opts.unit)}${r.sub ? ` · ${r.sub}` : ""}`)}">` +
        `<span class="mc-bar-lab">${esc(r.label)}</span>` +
        `<span class="mc-bar-track"><i style="width:${w.toFixed(2)}%;background:${color}"></i></span>` +
        `<span class="mc-bar-val">${esc(fmtValue(v, opts.unit))}</span>` +
        `${r.sub ? `<span class="mc-bar-sub">${esc(r.sub)}</span>` : ""}` +
        `</${tag}>`
      );
    })
    .join("");
  return `<div class="mc-bars" role="img" aria-label="${esc(opts.aria || "排序")}">${body}</div>`;
}

/** Line + area for ordered series (>= 3 points). Never for < 3 points. */
export function lineChart(points, opts = {}) {
  const pts = (points || []).filter((p) => Number.isFinite(Number(p.value)));
  if (pts.length < 3) return "";
  const w = Number(opts.width) || 520;
  const h = Number(opts.height) || 92;
  const padL = 34;
  const padR = 6;
  const padT = 8;
  const padB = 16;
  const max = Math.max(...pts.map((p) => Number(p.value) || 0), 0);
  const min = Math.min(...pts.map((p) => Number(p.value) || 0), 0);
  const span = max - min || 1;
  const x = (i) => padL + ((w - padL - padR) * i) / Math.max(1, pts.length - 1);
  const y = (v) => padT + (h - padT - padB) * (1 - ((Number(v) || 0) - min) / span);
  const color = opts.color || "#2f8f83";
  const line = pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.value).toFixed(1)}`).join(" ");
  const area = `${line} L${x(pts.length - 1).toFixed(1)},${(h - padB).toFixed(1)} L${x(0).toFixed(1)},${(h - padB).toFixed(1)} Z`;
  const dots = pts
    .map((p, i) => `<circle cx="${x(i).toFixed(1)}" cy="${y(p.value).toFixed(1)}" r="2.2" fill="${color}"><title>${esc(`${p.label} ${fmtValue(p.value, opts.unit)}`)}</title></circle>`)
    .join("");
  const grid = [0, 0.5, 1]
    .map((f) => {
      const yy = padT + (h - padT - padB) * f;
      const val = max - span * f;
      return (
        `<line x1="${padL}" y1="${yy.toFixed(1)}" x2="${w - padR}" y2="${yy.toFixed(1)}" stroke="rgba(60,60,67,0.12)" stroke-width="1"></line>` +
        `<text x="${padL - 5}" y="${(yy + 3.5).toFixed(1)}" text-anchor="end" class="mc-axis">${esc(fmtCompact(val))}</text>`
      );
    })
    .join("");
  const xlab =
    `<text x="${padL}" y="${h - 3}" class="mc-axis">${esc(pts[0].label)}</text>` +
    `<text x="${w - padR}" y="${h - 3}" text-anchor="end" class="mc-axis">${esc(pts[pts.length - 1].label)}</text>`;
  const last = pts[pts.length - 1];
  const head = opts.title
    ? `<div class="mc-line-head"><span>${esc(opts.title)}</span><b>${esc(fmtValue(last.value, opts.unit))}</b>` +
      (opts.deltaText ? `<em>${esc(opts.deltaText)}</em>` : "") +
      `</div>`
    : "";
  return (
    `<div class="mc-line" role="img" aria-label="${esc(opts.aria || "趋势")}">${head}` +
    `<svg width="100%" height="${h}" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">` +
    `${grid}<path d="${area}" fill="${color}" opacity="0.14"></path>` +
    `<path d="${line}" fill="none" stroke="${color}" stroke-width="1.8" stroke-linejoin="round"></path>${dots}${xlab}</svg></div>`
  );
}

/** Ordered columns: shape across many points (per-turn wall/cost). */
export function columns(rows, opts = {}) {
  const items = (rows || []).filter((r) => r && Number.isFinite(Number(r.value)));
  if (!items.length) return `<div class="mc-empty">${esc(opts.empty || "无数据")}</div>`;
  const w = Number(opts.width) || 560;
  const h = Number(opts.height) || 56;
  const max = Math.max(...items.map((r) => Number(r.value) || 0), 1);
  const gap = items.length > 80 ? 0.5 : 1.5;
  const bw = Math.max(1, (w - gap * (items.length - 1)) / items.length);
  const bars = items
    .map((r, i) => {
      const v = Number(r.value) || 0;
      const bh = Math.max(1.5, (h - 4) * (v / max));
      const color = r.color || colorAt(0);
      const xx = i * (bw + gap);
      const attr = r.jump ? ` class="mc-col" data-mine-turn="${esc(r.jump)}"` : ` class="mc-col"`;
      return (
        `<rect${attr} x="${xx.toFixed(2)}" y="${(h - bh).toFixed(2)}" width="${bw.toFixed(2)}" height="${bh.toFixed(2)}" ` +
        `rx="${Math.min(2, bw / 2).toFixed(2)}" fill="${color}">` +
        `<title>${esc(`${r.label} ${fmtValue(v, opts.unit)}${r.note ? ` · ${r.note}` : ""}`)}</title></rect>` +
        (r.flag ? `<circle cx="${(xx + bw / 2).toFixed(2)}" cy="${Math.max(1.6, h - bh - 3).toFixed(2)}" r="1.8" fill="${SEV_COLORS.high}"></circle>` : "")
      );
    })
    .join("");
  const head = opts.title
    ? `<div class="mc-line-head"><span>${esc(opts.title)}</span><b>${esc(fmtValue(opts.total, opts.unit))}</b>` +
      (opts.deltaText ? `<em>${esc(opts.deltaText)}</em>` : "") +
      `</div>`
    : "";
  return (
    `<div class="mc-cols" role="img" aria-label="${esc(opts.aria || "分布")}">${head}` +
    `<svg width="100%" height="${h}" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${bars}</svg>` +
    `<div class="mc-axis-row"><span>${esc(opts.axisLeft || "")}</span><span>${esc(opts.axisRight || "")}</span></div></div>`
  );
}

/** Pick a chart kind from the data itself (declared by the backend per table). */
export function chartFor(kind, rows, opts = {}) {
  if (kind === "bars") return rankBars(rows, opts);
  if (kind === "donut") return donut(rows, opts);
  if (kind === "line") return lineChart(rows, opts);
  if (kind === "columns") return columns(rows, opts);
  if (kind === "stack") return stackBar(rows, opts);
  return "";
}

/**
 * ECharts placeholder. The shared renderer still decides *which* chart, which
 * unit and which semantic colour (the taste); the React app mounts the actual
 * ECharts instance from this spec (docs/design-web-frontend.md §5: charts are
 * declarative wrappers around ECharts with the design tokens). The vanilla
 * rollback keeps using the SVG builders above.
 */
export function echart(kind, rows, opts = {}) {
  const items = (rows || [])
    .map((r, i) => ({
      label: String((r && r.label) ?? ""),
      value: Number((r && r.value) ?? 0),
      color: (r && r.color) || colorAt(i),
      flag: !!(r && r.flag),
      jump: r && r.jump != null ? r.jump : null,
      sub: String((r && r.sub) ?? ""),
      note: String((r && r.note) ?? ""),
    }))
    .filter((r) => r.label !== "" || r.value !== 0);
  if (!items.length) return `<div class="mc-empty">${esc(opts.empty || "无数据")}</div>`;
  const spec = {
    kind,
    unit: opts.unit || "",
    items,
    center: opts.center || "",
    centerSub: opts.centerSub || "",
    title: opts.title || "",
    total: Number.isFinite(Number(opts.total)) ? Number(opts.total) : null,
    axisLeft: opts.axisLeft || "",
    axisRight: opts.axisRight || "",
  };
  const h =
    Number(opts.height) ||
    (kind === "bars" ? Math.max(30, items.length * 28) : kind === "donut" ? 156 : kind === "stack" ? 46 : 64);
  return (
    `<div class="mc-echart" role="img" aria-label="${esc(opts.aria || "图表")}" ` +
    `data-mc="${esc(JSON.stringify(spec))}" style="height:${h}px"></div>`
  );
}
