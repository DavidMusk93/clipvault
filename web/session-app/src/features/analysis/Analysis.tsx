import { AlertTriangle } from "lucide-react";
import { type MineBlock, type MineTable, useMine } from "../../api/mine";
import { Badge } from "../../components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "../../components/ui/card";
import { Table, Td, Th } from "../../components/ui/table";
import { Chart } from "./Chart";

const MAX_ROWS = 30;

function Kpi({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return (
    <div className="min-w-[92px] rounded-lg bg-white/70 px-3 py-2 ring-1 ring-black/5">
      <div className="text-[10px] text-role-system">{label}</div>
      <div className={`text-[15px] font-semibold ${tone ?? "text-ink"}`}>{value}</div>
    </div>
  );
}

function fmtNum(v: unknown): string {
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isFinite(n)) return String(v ?? "—");
  if (Math.abs(n) >= 1000) return n.toLocaleString();
  return String(Math.round(n * 1000) / 1000);
}

function BlockTable({ table }: { table: MineTable }) {
  const rows = (table.rows ?? []).slice(0, MAX_ROWS);
  const cols = table.cols ?? [];
  return (
    <div className="mb-3">
      {table.caption && (
        <div className="mb-1 text-[11px] font-medium text-role-system">{table.caption}</div>
      )}
      {table.chart && rows.length > 0 && (
        <div className="mb-2 rounded-lg bg-white/60 p-1">
          <Chart spec={table.chart} rows={rows} />
        </div>
      )}
      {cols.length > 0 && (
        <Table>
          <thead>
            <tr>
              {cols.map((c) => (
                <Th key={c.id}>{c.title}</Th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              // biome-ignore lint/suspicious/noArrayIndexKey: rows are positional facts
              <tr key={i}>
                {cols.map((c) => (
                  <Td key={c.id}>{fmtNum(r[c.id])}</Td>
                ))}
              </tr>
            ))}
          </tbody>
        </Table>
      )}
    </div>
  );
}

function Block({ block }: { block: MineBlock }) {
  const tables = block.tables ?? (block.table ? [block.table] : []);
  return (
    <Card>
      <CardHeader>
        <CardTitle>{block.title}</CardTitle>
        <Badge>{block.axis}</Badge>
      </CardHeader>
      <CardContent>
        {block.note && (
          <p className="mb-2 text-[11px] leading-relaxed text-role-system">{block.note}</p>
        )}
        {tables.map((t, i) => (
          // biome-ignore lint/suspicious/noArrayIndexKey: block tables are ordered facts
          <BlockTable key={i} table={t} />
        ))}
      </CardContent>
    </Card>
  );
}

export default function Analysis() {
  const mine = useMine("recent", [], true);

  if (mine.isPending) return <p className="p-4 text-[12px] text-role-system">分析中…</p>;
  if (mine.isError)
    return <p className="p-4 text-[12px] text-mine-loss">分析失败：{String(mine.error)}</p>;

  const d = mine.data;
  const h = d.summary?.health;
  const blocks = Object.entries(d.blocks ?? {});

  return (
    <div className="flex flex-col gap-3 p-3">
      <div className="flex flex-wrap items-center gap-2">
        {h && (
          <div className="flex items-center gap-2 rounded-lg bg-honey/10 px-3 py-2 ring-1 ring-honey/20">
            <span className="text-[20px] font-semibold text-honey">{h.score}</span>
            <span className="text-[12px] font-medium text-honey">{h.grade}</span>
          </div>
        )}
        <Kpi label="回合" value={fmtNum(d.summary?.n_turns ?? 0)} />
        <Kpi label="工具" value={fmtNum(d.summary?.n_tools ?? 0)} />
        <Kpi label="费用" value={`$${fmtNum(d.summary?.cost_usd ?? 0)}`} tone="text-honey" />
        <Kpi label="缓存命中" value={`${fmtNum(d.summary?.cache_hit_pct ?? 0)}%`} />
        <Kpi label="浪费" value={`${fmtNum(h?.waste_pct ?? 0)}%`} />
        <Kpi label="失败" value={fmtNum(h?.fail_rate ?? 0) + "%"} />
      </div>

      {(d.findings ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>结论与动作</CardTitle>
            <span className="text-[10px] text-role-system">{d.findings?.length} 条</span>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            {(d.findings ?? []).map((f) => (
              <div key={f.id} className="rounded-lg border border-black/5 p-3">
                <div className="mb-1 flex items-center gap-2">
                  <Badge sev={f.sev}>{f.sev}</Badge>
                  <span className="text-[12px] font-semibold">{f.title}</span>
                  <span className="ml-auto text-[10px] text-role-system">
                    {fmtNum(f.impact.s)}s / ${fmtNum(f.impact.usd)} · {f.impact.kind}
                  </span>
                </div>
                <p className="text-[11px] leading-relaxed text-ink/80">{f.text}</p>
                {f.action && (
                  <p className="mt-1 flex items-start gap-1 text-[11px] leading-relaxed text-role-assistant">
                    <AlertTriangle size={12} className="mt-0.5 shrink-0" />
                    {f.action}
                  </p>
                )}
                {f.ack && (
                  <p className="mt-1 text-[10px] text-role-system">
                    闭环：[{f.ack.status}]{" "}
                    {f.ack.closed === true
                      ? "已达成"
                      : f.ack.closed === false
                        ? "未改善"
                        : "无目标"}
                  </p>
                )}
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {(d.losses ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>损耗账本</CardTitle>
            <span className="text-[10px] text-role-system">按 $ / 秒</span>
          </CardHeader>
          <CardContent>
            <Table>
              <thead>
                <tr>
                  <Th>损耗</Th>
                  <Th>秒</Th>
                  <Th>USD</Th>
                  <Th>类型</Th>
                </tr>
              </thead>
              <tbody>
                {(d.losses ?? []).map((l) => (
                  <tr key={l.id}>
                    <Td>{l.label}</Td>
                    <Td>{fmtNum(l.s)}</Td>
                    <Td>{fmtNum(l.usd)}</Td>
                    <Td className="text-role-system">{l.kind}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </CardContent>
        </Card>
      )}

      {(d.metrics ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>指标</CardTitle>
            <span className="text-[10px] text-role-system">Δ = 对基线</span>
          </CardHeader>
          <CardContent>
            <Table>
              <thead>
                <tr>
                  <Th>指标</Th>
                  <Th>值</Th>
                  <Th>目标</Th>
                  <Th>Δ</Th>
                </tr>
              </thead>
              <tbody>
                {(d.metrics ?? []).map((m) => (
                  <tr key={m.id}>
                    <Td>{m.label}</Td>
                    <Td>
                      {fmtNum(m.value)}
                      {m.unit}
                    </Td>
                    <Td className="text-role-system">
                      {m.target == null ? "—" : `${fmtNum(m.target)}${m.unit}`}
                    </Td>
                    <Td className={m.delta == null ? "text-role-system" : "text-honey"}>
                      {m.delta == null ? "—" : (m.delta > 0 ? "+" : "") + fmtNum(m.delta)}
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </CardContent>
        </Card>
      )}

      {blocks.map(([id, b]) => (
        <Block key={id} block={b} />
      ))}
    </div>
  );
}
