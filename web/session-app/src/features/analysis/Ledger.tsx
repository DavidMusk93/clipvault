import { useMemo, useState } from "react";
import type { Mine, MineBlock, MineTable } from "../../api/mine";
import { cn } from "../../lib/cn";
import {
  colorAt,
  filterRows,
  fmtValue,
  isKnownPhase,
  isKvTable,
  isTotalLabel,
  isTurnTable,
  ledgerChart,
  MINE_NUM_COLS,
  nextSort,
  pct,
  phaseColor,
  phaseLabel,
  type SortState,
  sortRows,
  splitPath,
} from "./lib";
import { MineChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

type Row = Record<string, unknown>;

/** Path cells keep the file name: the directory is what gives way. */
function TextCell({ v }: { v: unknown }) {
  const { dir, base } = splitPath(v);
  if (!dir) return <span className="block truncate">{String(v ?? "")}</span>;
  return (
    <span className="flex min-w-0" title={String(v)}>
      <span className="min-w-0 truncate text-role-system [direction:rtl]">
        <bdi>{dir}</bdi>
      </span>
      <span className="shrink-0">{base}</span>
    </span>
  );
}

/** `metric | value` facts as tiles: one glance, no two-column list. */
function KvTiles({ t }: { t: MineTable }) {
  const rows = t.rows || [];
  if (!rows.length) return null;
  return (
    <div className="mt-2">
      {t.caption && <Caption text={t.caption} />}
      <dl className="grid grid-cols-2 gap-px overflow-hidden rounded-[10px] bg-black/[0.06] @md:grid-cols-3 @3xl:grid-cols-4">
        {rows.map((r) => (
          <div key={String(r.metric)} className="bg-white px-3 py-2">
            <dt className="truncate text-[11.5px] text-role-system">{String(r.metric)}</dt>
            <dd className="text-[15px] font-semibold tabular-nums tracking-[-0.01em] text-ink">
              {String(r.value ?? "—")}
            </dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function Caption({ text, n, of }: { text: string; n?: number; of?: number }) {
  return (
    <div className="mb-1 flex shrink-0 items-baseline gap-2 whitespace-nowrap text-[12px] font-medium text-role-system">
      <span>{text}</span>
      {n != null && of != null && n !== of && (
        <span className="tabular-nums">
          {n}/{of}
        </span>
      )}
    </div>
  );
}

/** Chart beside (wide) or above (narrow) its table; both light the same row. */
function TableChart({
  t,
  rows,
  hot,
  onHot,
}: {
  t: MineTable;
  rows: Row[];
  hot: number | null;
  onHot: (i: number | null) => void;
}) {
  const c = t.chart;
  if (!c || !rows.length) return null;
  const parts = rows.filter((r) => !isTotalLabel(r[c.label]));
  const picked = ledgerChart(
    c.kind,
    parts.map((r) => ({ value: Number(r[c.value] ?? 0) })),
  );
  if (!picked) return null;
  const items = parts.map((r, i) => {
    const raw = String(r[c.label] ?? "");
    const phase = isKnownPhase(raw) || raw === "other";
    return {
      label: phase ? phaseLabel(raw) : raw,
      value: Number(r[c.value] ?? 0),
      color: phase ? phaseColor(raw, i) : colorAt(i),
      flag: Number(r.fails || 0) > 0,
    };
  });
  // Map chart index <-> table row index (totals are table-only).
  const toRow = (i: number | null) => (i == null ? null : rows.indexOf(parts[i]));
  const fromRow = hot == null ? null : parts.indexOf(rows[hot]);
  const unit = c.unit || "";
  if (picked === "donut") {
    const total = items.reduce((a, it) => a + it.value, 0);
    const lit = fromRow != null && fromRow >= 0 ? items[fromRow] : null;
    return (
      <div className="relative size-[132px] shrink-0">
        <MineChart
          spec={{ kind: "donut", unit, items }}
          height={132}
          onHover={(i) => onHot(toRow(i))}
          highlight={fromRow}
        />
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center text-center">
          <b className="text-[17px] font-semibold leading-none tabular-nums text-ink">
            {lit ? `${pct(lit.value, total).toFixed(0)}%` : fmtValue(total, unit)}
          </b>
          <span className="mt-1 max-w-[80px] truncate text-[11px] text-role-system">
            {lit ? lit.label : "合计"}
          </span>
        </div>
      </div>
    );
  }
  const h = picked === "stack" ? 16 : picked === "line" ? 88 : 72;
  return (
    <MineChart
      spec={{ kind: picked, unit, items }}
      height={h}
      onHover={(i) => onHot(toRow(i))}
      highlight={fromRow}
      className={picked === "stack" ? "my-1" : ""}
    />
  );
}

function DataTable({ t }: { t: MineTable }) {
  const cols = t.cols || [];
  const all = (t.rows || []) as Row[];
  const [sort, setSort] = useState<SortState>(null);
  const [query, setQuery] = useState("");
  const [hot, setHot] = useState<number | null>(null);
  const textCols = cols.filter((c) => !MINE_NUM_COLS.has(c.id));
  const rows = useMemo(
    () => sortRows(filterRows(all, textCols, query), sort),
    [all, textCols, query, sort],
  );
  if (!cols.length || !all.length) return null;
  const maxima: Record<string, number> = {};
  for (const c of cols) {
    if (MINE_NUM_COLS.has(c.id))
      maxima[c.id] = Math.max(0, ...all.map((r) => Number(r[c.id]) || 0));
  }
  const chart = t.chart
    ? ledgerChart(
        t.chart.kind,
        all.map((r) => ({ value: Number(r[t.chart?.value ?? ""] ?? 0) })),
      )
    : null;
  const side = chart === "donut";
  // Chart reads rows in table order, so it follows sort/filter too.
  const chartEl = <TableChart t={t} rows={rows} hot={hot} onHot={setHot} />;
  return (
    <div className="mt-3 first:mt-1">
      <div className="flex items-center gap-2">
        {t.caption ? <Caption text={t.caption} n={rows.length} of={all.length} /> : <span />}
        {all.length > 8 && (
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="筛选"
            aria-label={`筛选${t.caption || ""}`}
            className="mb-1 ml-auto h-6 w-28 min-w-0 rounded-[6px] bg-black/[0.05] px-2 text-[12px] text-ink outline-none placeholder:text-role-system focus:bg-white focus:ring-2 focus:ring-accent/30"
          />
        )}
      </div>
      <div className={cn(side ? "flex items-start gap-4" : "")}>
        {chartEl}
        <table className="w-full min-w-0 table-fixed border-collapse text-[12.5px]">
          <thead>
            <tr>
              {cols.map((c) => {
                const num = MINE_NUM_COLS.has(c.id);
                const on = sort?.key === c.id;
                return (
                  <th
                    key={c.id}
                    aria-sort={on ? (sort?.dir === "asc" ? "ascending" : "descending") : "none"}
                    className={cn(
                      "border-b border-black/[0.08] p-0 font-normal",
                      num ? "w-[76px] text-right" : "text-left",
                    )}
                  >
                    <button
                      type="button"
                      onClick={() => setSort((s) => nextSort(s, c.id))}
                      className={cn(
                        "h-7 w-full truncate px-2 text-[11.5px] hover:text-ink",
                        num ? "text-right" : "text-left",
                        on ? "font-semibold text-ink" : "text-role-system",
                      )}
                    >
                      {c.title}
                      {on ? (sort?.dir === "asc" ? " ↑" : " ↓") : ""}
                    </button>
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, ri) => (
              <tr
                // biome-ignore lint/suspicious/noArrayIndexKey: rows are positional facts.
                key={ri}
                onPointerEnter={() => setHot(ri)}
                onPointerLeave={() => setHot(null)}
                className={cn(
                  hot === ri && "bg-black/[0.035]",
                  isTotalLabel(row[cols[0]?.id]) && "font-semibold",
                )}
              >
                {cols.map((c) => {
                  const raw = row[c.id] ?? "";
                  if (!MINE_NUM_COLS.has(c.id)) {
                    return (
                      <td key={c.id} className="h-7 border-b border-black/[0.05] px-2 text-ink">
                        <TextCell v={raw} />
                      </td>
                    );
                  }
                  const v = Number(raw) || 0;
                  const w =
                    maxima[c.id] && v > 0 ? Math.max(3, Math.round((100 * v) / maxima[c.id])) : 0;
                  return (
                    <td
                      key={c.id}
                      className="h-7 border-b border-black/[0.05] px-2 text-right tabular-nums text-ink"
                    >
                      <span className="relative flex items-center justify-end">
                        <i
                          className="absolute inset-y-[2px] right-0 bg-honey/20"
                          style={{ width: `${w}%` }}
                        />
                        <span className="relative">{String(raw)}</span>
                      </span>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {query && !rows.length && (
        <p className="py-2 text-[12px] text-role-system">没有匹配「{query}」的行</p>
      )}
    </div>
  );
}

/** Wide tables (≥4 columns) need the full width; the rest pair up. */
const isWide = (tables: MineTable[]) => tables.some((t) => (t.cols || []).length >= 4);

function Block({ id, b, onJump }: { id: string; b: MineBlock; onJump: (id: string) => void }) {
  const axis = b.axis === "user" ? "user" : "agent";
  const all = b.tables?.length ? b.tables : b.table ? [b.table] : [];
  const turnTables = all.filter((t) => isTurnTable(t.cols));
  const tables = all.filter((t) => !isTurnTable(t.cols));
  const empty = !tables.some((t) => (t.rows || []).length);
  return (
    <section
      id={`blk-${id}`}
      className={cn(
        "min-w-0 scroll-mt-4 rounded-[14px] border border-black/[0.06] bg-white px-4 py-3",
        "mb-3 break-inside-avoid",
      )}
    >
      <div className="flex items-center gap-2">
        <i
          className={cn(
            "size-2 shrink-0 rounded-full",
            axis === "user" ? "bg-role-user" : "bg-role-assistant",
          )}
        />
        <h3 className="flex-1 truncate text-[14px] font-semibold tracking-[-0.01em] text-ink">
          {b.title || id}
        </h3>
        <span className="text-[11.5px] text-role-system">
          {axis === "user" ? "用户侧" : "Agent 侧"}
        </span>
      </div>
      {b.note && <p className="mt-1 text-[12px] leading-snug text-role-system">{b.note}</p>}
      {tables.map((t, i) =>
        isKvTable(t.cols) ? (
          <KvTiles key={t.caption || i} t={t} />
        ) : (
          <DataTable key={t.caption || i} t={t} />
        ),
      )}
      {empty && !turnTables.length && (
        <p className="mt-2 text-[12px] text-role-system">本窗口没有记录</p>
      )}
      {turnTables.length > 0 && (
        <button
          type="button"
          onClick={() => onJump("mineTimeline")}
          className="mt-2 text-[12px] text-role-assistant hover:underline"
        >
          {turnTables.map((t) => t.caption || "逐回合").join("、")}：逐回合
          {(turnTables[0]?.rows || []).length} 行已并入 ③ 回合 →
        </button>
      )}
    </section>
  );
}

/** ④ 账本 · 事实: always expanded, packed two-up; every table sorts and filters. */
export function Ledger({ data, onJump }: { data: Mine; onJump: (id: string) => void }) {
  const active = data.active || null;
  const blocks = Object.entries(data.blocks || {}).filter(([id]) => !active || active.includes(id));
  if (!blocks.length) return null;
  const tablesOf = (b: MineBlock) => (b.tables?.length ? b.tables : b.table ? [b.table] : []);
  const wideOf = (b: MineBlock) =>
    isWide(tablesOf(b).filter((t) => !isTurnTable(t.cols) && !isKvTable(t.cols)));
  const narrow = blocks.filter(([, b]) => !wideOf(b));
  const wide = blocks.filter(([, b]) => wideOf(b));
  return (
    <Section id="mineLedger">
      <SectionHead title="账本" count={blocks.length} hint="事实计数 · 点表头排序 · 悬停联动图表" />
      {/* Narrow blocks flow as masonry columns (no row-stretch gaps); blocks with
          ≥4-column tables need the full width and follow. */}
      <div className="gap-3 @2xl:columns-2">
        {narrow.map(([id, b]) => (
          <Block key={id} id={id} b={b} onJump={onJump} />
        ))}
      </div>
      {wide.map(([id, b]) => (
        <Block key={id} id={id} b={b} onJump={onJump} />
      ))}
    </Section>
  );
}
