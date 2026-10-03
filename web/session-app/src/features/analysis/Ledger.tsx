import type { Mine, MineTable } from "../../api/mine";
import { Table, Td, Th } from "../../components/ui/table";
import { colorAt, isKnownPhase, MINE_NUM_COLS, phaseColor, phaseLabel, pickKind } from "./lib";
import { AnalysisChart } from "./MineChart";
import { Section, SectionHead } from "./Section";

function TableChart({ t }: { t: MineTable }) {
  const c = t.chart;
  if (!c) return null;
  const rows = t.rows || [];
  if (!rows.length) return null;
  const picked = pickKind(
    c.kind,
    rows.map((r) => ({ value: Number(r[c.value] ?? 0) })),
  );
  const items = rows.map((r, i) => {
    const raw = String(r[c.label] ?? "");
    const phase = isKnownPhase(raw);
    const label = (picked === "donut" || picked === "columns") && phase ? phaseLabel(raw) : raw;
    return {
      label,
      value: Number(r[c.value] ?? 0),
      color: picked === "donut" || picked === "columns" ? phaseColor(raw, i) : colorAt(i),
      flag: Number(r.fails || 0) > 0,
      jump: r.index as number | undefined,
    };
  });
  return (
    <div className="my-2">
      <AnalysisChart kind={c.kind} items={items} unit={c.unit || ""} centerSub={t.caption} />
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
    <div className="mt-3 first:mt-1">
      {t.caption && (
        <div className="mb-1.5 text-[12px] font-medium text-role-system">{t.caption}</div>
      )}
      <TableChart t={t} />
      <Table className="mt-2 text-[12.5px]">
        <thead>
          <tr>
            {cols.map((c) => (
              <Th
                key={c.id}
                className={`py-1.5 font-normal ${MINE_NUM_COLS.has(c.id) ? "text-right" : ""}`}
              >
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
                    <Td key={c.id} className="max-w-[300px] truncate py-1.5" title={String(raw)}>
                      {String(raw)}
                    </Td>
                  );
                }
                const v = Number(raw) || 0;
                const pct = maxima[c.id] ? Math.max(3, Math.round((100 * v) / maxima[c.id])) : 0;
                return (
                  <Td key={c.id} className="py-1.5 text-right tabular-nums">
                    <span className="relative inline-flex min-w-[56px] items-center justify-end">
                      <i
                        className="absolute inset-y-[3px] left-0 bg-honey/25"
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
    </div>
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
      <div className="flex flex-col gap-3">
        {blocks.map(([id, b]) => {
          const axis = b.axis === "user" ? "user" : "agent";
          const tables = b.tables?.length ? b.tables : b.table ? [b.table] : [];
          return (
            <section
              key={id}
              id={`blk-${id}`}
              className={`scroll-mt-12 rounded-[14px] border border-black/[0.06] border-l-2 bg-white p-4 ${
                axis === "user" ? "border-l-role-user" : "border-l-role-assistant"
              }`}
            >
              <div className="mb-1.5 flex items-baseline gap-2">
                <span className="text-[11px] font-semibold uppercase tracking-[0.05em] text-role-system">
                  {axis === "user" ? "用户" : "Agent"}
                </span>
                <h3
                  className={`flex-1 text-[14px] font-semibold tracking-[-0.01em] ${
                    axis === "user" ? "text-role-user" : "text-role-assistant"
                  }`}
                >
                  {b.title || id}
                </h3>
              </div>
              {b.note && (
                <p className="mb-1 text-[12.5px] leading-relaxed text-role-system">{b.note}</p>
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
