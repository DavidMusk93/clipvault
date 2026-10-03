import type { Mine, MineTable } from "../../api/mine";
import { Table, Td, Th } from "../../components/ui/table";
import { colorAt, fmtValue, isKnownPhase, MINE_NUM_COLS, phaseColor, phaseLabel } from "./lib";
import { MineChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

const KINDS = ["stack", "donut", "bars", "columns", "line"] as const;
type Kind = (typeof KINDS)[number];
const kindOf = (k: string): Kind =>
  (KINDS as readonly string[]).includes(k) ? (k as Kind) : "bars";

function TableChart({ t }: { t: MineTable }) {
  const c = t.chart;
  if (!c) return null;
  const rows = t.rows || [];
  if (!rows.length) return null;
  const kind = kindOf(c.kind);
  const items = rows.map((r, i) => {
    const raw = String(r[c.label] ?? "");
    const phase = isKnownPhase(raw);
    const label = (kind === "donut" || kind === "columns") && phase ? phaseLabel(raw) : raw;
    return {
      label,
      value: Number(r[c.value] ?? 0),
      color: kind === "donut" || kind === "columns" ? phaseColor(raw, i) : colorAt(i),
      flag: Number(r.fails || 0) > 0,
      jump: r.index as number | undefined,
    };
  });
  const total = items.reduce((a, it) => a + it.value, 0);
  const height =
    kind === "donut"
      ? 124
      : kind === "columns"
        ? 52
        : kind === "stack"
          ? 16
          : kind === "bars"
            ? Math.max(30, items.length * 28)
            : 64;
  const chart = <MineChart spec={{ kind, unit: c.unit || "", items }} height={height} />;
  if (kind !== "donut") return <div className="my-1.5">{chart}</div>;
  return (
    <div className="relative my-1.5 max-w-[420px]">
      {chart}
      <div className="pointer-events-none absolute left-[38%] top-1/2 -translate-x-1/2 -translate-y-1/2 text-center">
        <b className="block text-[22px] font-bold leading-none text-ink tabular-nums">
          {fmtValue(total, c.unit || "")}
        </b>
        {t.caption && (
          <span className="mt-0.5 block text-[11px] text-role-system">{t.caption}</span>
        )}
      </div>
    </div>
  );
}

function DataTable({ t }: { t: MineTable }) {
  const cols = t.cols || [];
  const rows = t.rows || [];
  if (!cols.length || !rows.length) return null;
  const maxima: Record<string, number> = {};
  for (const c of cols) {
    if (!MINE_NUM_COLS.has(c.id)) continue;
    maxima[c.id] = Math.max(0, ...rows.map((r) => Number(r[c.id]) || 0));
  }
  return (
    <>
      {t.caption && (
        <div className="mt-1.5 text-[11px] font-medium text-role-system">{t.caption}</div>
      )}
      <TableChart t={t} />
      <Table className="mt-1">
        <thead>
          <tr>
            {cols.map((c) => (
              <Th key={c.id} className={MINE_NUM_COLS.has(c.id) ? "text-right" : undefined}>
                {c.title}
              </Th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, ri) => (
            // biome-ignore lint/suspicious/noArrayIndexKey: rows are positional facts.
            <tr key={ri}>
              {cols.map((c) => {
                const raw = row[c.id] ?? "";
                if (!MINE_NUM_COLS.has(c.id)) {
                  return (
                    <Td key={c.id} className="max-w-[280px] truncate" title={String(raw)}>
                      {String(raw)}
                    </Td>
                  );
                }
                const v = Number(raw) || 0;
                const pct = maxima[c.id] ? Math.max(3, Math.round((100 * v) / maxima[c.id])) : 0;
                return (
                  <Td key={c.id} className="text-right tabular-nums">
                    <span className="relative inline-flex min-w-[52px] items-center justify-end">
                      <i
                        className="absolute inset-y-[3px] left-0 rounded bg-honey/25"
                        style={{ width: `${pct}%` }}
                      />
                      <span className="relative">{String(raw)}</span>
                    </span>
                  </Td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </Table>
    </>
  );
}

/** ④ 账本 · 事实: always expanded. */
export function Ledger({ data }: { data: Mine }) {
  const active = data.active || null;
  const blocks = Object.entries(data.blocks || {}).filter(([id]) => !active || active.includes(id));
  if (!blocks.length) return null;
  return (
    <Section id="mineLedger">
      <SectionHead title="账本 · 事实" count={blocks.length} hint="始终展开" />
      <div className="flex flex-col gap-2">
        {blocks.map(([id, b]) => {
          const axis = b.axis === "user" ? "user" : "agent";
          const tables = b.tables?.length ? b.tables : b.table ? [b.table] : [];
          return (
            <section
              key={id}
              id={`blk-${id}`}
              className={`scroll-mt-11 rounded-xl border border-black/5 border-l-2 bg-white px-3 py-2 ${
                axis === "user" ? "border-l-role-user" : "border-l-role-assistant"
              }`}
            >
              <div className="mb-1 flex items-baseline gap-2">
                <span className="text-[10.5px] font-semibold uppercase tracking-[0.04em] text-role-system">
                  {axis === "user" ? "用户" : "Agent"}
                </span>
                <h3
                  className={`flex-1 text-[13px] font-semibold ${
                    axis === "user" ? "text-role-user" : "text-role-assistant"
                  }`}
                >
                  {b.title || id}
                </h3>
              </div>
              {b.note && (
                <p className="mb-1 text-[11.5px] leading-snug text-role-system">{b.note}</p>
              )}
              {tables.map((t, i) => (
                <DataTable key={t.caption || i} t={t} />
              ))}
            </section>
          );
        })}
      </div>
    </Section>
  );
}
