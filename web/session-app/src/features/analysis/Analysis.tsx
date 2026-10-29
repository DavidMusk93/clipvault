import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { ackFinding, getMine, type Mine, type MineFinding } from "../../api/mine";
import { cn } from "../../lib/cn";
import { Ledger } from "./Ledger";
import { Losses } from "./Losses";
import { mineDraftMarkdown, windowText } from "./lib";
import { Timeline } from "./Timeline";
import { Verdict } from "./Verdict";

const MINE_KEY = "cv.trae.mine.v1";
const AUTO_MS = 15000;

type Scope = "session" | "recent";

function readSaved(): { scope: Scope; dirs: string[] } {
  try {
    const saved = JSON.parse(localStorage.getItem(MINE_KEY) || "null") as {
      scope?: string;
      dirs?: unknown;
    } | null;
    if (saved && typeof saved === "object") {
      return {
        scope: saved.scope === "recent" ? "recent" : "session",
        dirs: Array.isArray(saved.dirs)
          ? saved.dirs.filter((d): d is string => typeof d === "string")
          : [],
      };
    }
  } catch {
    /* ignore */
  }
  return { scope: "session", dirs: [] };
}

/**
 * 「分析」sheet — rebuilt from the taste (docs/design-taste.md 「分析」), styled on
 * Apple HIG: 8pt spacing grid, SF type scale, grouped white cards on the system
 * grouped background, controls ≥28px, chrome kept out of the way.
 * ① 判定（分数 + 损耗构成 + 费用）→ ② 发现 → ③ 回合 → ④ 账本.
 */
export default function Analysis({
  sessionId,
  onClose,
}: {
  sessionId: string;
  onClose: () => void;
}) {
  const saved = useMemo(readSaved, []);
  const [scope, setScope] = useState<Scope>(saved.scope);
  const [dirs, setDirs] = useState<string[]>(saved.dirs);
  const [openTurn, setOpenTurn] = useState<number | null>(null);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [copyLabel, setCopyLabel] = useState("复制草稿");
  const scrollRef = useRef<HTMLDivElement>(null);

  const persist = (nextScope: Scope, nextDirs: string[]) => {
    try {
      localStorage.setItem(MINE_KEY, JSON.stringify({ scope: nextScope, dirs: nextDirs }));
    } catch {
      /* ignore */
    }
  };

  const q = useQuery({
    queryKey: ["mine", scope, dirs.join(","), sessionId],
    queryFn: () => getMine(scope, dirs, true, sessionId),
    staleTime: 30_000,
    refetchInterval: AUTO_MS,
    refetchIntervalInBackground: false,
  });
  const data: Mine | null = q.data ?? null;

  // biome-ignore lint/correctness/useExhaustiveDependencies: collapse the open turn when the scope changes.
  useEffect(() => {
    setOpenTurn(null);
  }, [scope, dirs, sessionId]);

  const directions = data?.directions ?? [];
  const findings = data?.findings || [];
  const activeDirs = dirs.length ? dirs : directions.map((d) => d.id);

  const toggleDir = (id: string) => {
    const base = dirs.length ? dirs.slice() : directions.map((d) => d.id);
    const i = base.indexOf(id);
    if (i >= 0) base.splice(i, 1);
    else base.push(id);
    setDirs(base);
    persist(scope, base);
  };

  const jump = (id: string) => {
    const el = scrollRef.current?.querySelector(`#${CSS.escape(id)}`);
    if (!el) return;
    el.scrollIntoView({ block: "start" });
  };

  const toggleTurn = (n: number) => setOpenTurn((prev) => (prev === n ? null : n));

  const onAck = async (f: MineFinding, status: string, btn?: HTMLElement) => {
    const m = f.metric;
    const label = btn?.textContent || "";
    if (btn) btn.textContent = "记录中…";
    try {
      await ackFinding({
        scope,
        session_id: scope === "session" ? sessionId : "",
        finding_id: f.id,
        status,
        metric: { id: m?.id || "", now: m?.now ?? null, target: m?.target ?? null },
      });
      await q.refetch();
    } catch {
      if (btn) {
        btn.textContent = "失败";
        window.setTimeout(() => {
          btn.textContent = label;
        }, 1500);
      }
    }
  };

  const copyDraft = async () => {
    if (!data) return;
    try {
      await navigator.clipboard.writeText(mineDraftMarkdown(data));
      setCopyLabel("已复制");
      window.setTimeout(() => setCopyLabel("复制草稿"), 1200);
    } catch {
      /* clipboard unavailable */
    }
  };

  const summary = useMemo(() => {
    if (!data?.ok) return null;
    const w = data.window || {};
    const s = data.summary || {};
    const tags: [string, string][] = [];
    if (w.truncated) tags.push(["已截断", "bg-mine-loss/12 text-mine-loss"]);
    if (data.baseline?.source)
      tags.push([`对照 ${data.baseline.source}`, "bg-black/[0.06] text-role-system"]);
    if (!s.usage_turns) tags.push(["无计费数据", "bg-mine-money/12 text-mine-money"]);
    return (
      <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] tabular-nums text-role-system">
        <span>
          {windowText(w) || "—"} · {s.n_turns || 0} 回合 · {s.n_tools || 0} 工具
          {w.instances?.length ? ` · ${w.instances.join(" / ")}` : ""}
        </span>
        {tags.map(([t, cls]) => (
          <span key={t} className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${cls}`}>
            {t}
          </span>
        ))}
      </p>
    );
  }, [data]);

  const navItems: [string, string, number | null][] = [
    ["mineVerdict", "判定", null],
    ["mineLosses", "发现", findings.length],
    ...((data?.turns?.length ? [["mineTimeline", "回合", data.turns.length]] : []) as [
      string,
      string,
      number,
    ][]),
    ["mineLedger", "账本", Object.keys(data?.blocks || {}).length],
  ];

  const pill =
    "h-7 rounded-full border border-black/10 bg-white px-3 text-[12.5px] font-medium text-ink hover:bg-black/[0.03] focus-visible:outline-2 focus-visible:outline-accent";

  return (
    <div className="absolute inset-x-2 bottom-[52px] top-2 z-10 flex min-h-0 flex-col overflow-hidden rounded-[18px] border border-black/10 bg-[#F5F5F7] shadow-[0_20px_60px_rgba(0,0,0,0.18)]">
      {/* Header: title + actions · scope + directions + jump links · window facts */}
      <div className="flex-none border-b border-black/[0.06] bg-[#F5F5F7] px-5 pb-3 pt-4">
        <div className="flex items-center gap-2">
          <h2 className="flex-1 text-[17px] font-semibold tracking-[-0.02em] text-ink">会话分析</h2>
          <button type="button" onClick={() => void copyDraft()} className={pill}>
            {copyLabel}
          </button>
          <button type="button" onClick={onClose} className={pill}>
            关闭
          </button>
        </div>
        <div className="mt-1">{summary}</div>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <fieldset
            aria-label="范围"
            className="inline-flex shrink-0 rounded-[9px] border-0 bg-black/[0.06] p-0.5"
          >
            {(["session", "recent"] as const).map((s) => (
              <button
                key={s}
                type="button"
                aria-pressed={scope === s}
                onClick={() => {
                  setScope(s);
                  persist(s, dirs);
                }}
                className={cn(
                  "h-7 rounded-[7px] px-3 text-[12.5px] font-medium transition-colors",
                  scope === s ? "bg-white text-ink shadow-sm" : "text-role-system hover:text-ink",
                )}
              >
                {s === "session" ? "当前会话" : "最近 7 天"}
              </button>
            ))}
          </fieldset>
          <button
            type="button"
            aria-expanded={filtersOpen}
            onClick={() => setFiltersOpen((v) => !v)}
            className={pill}
          >
            方向 {activeDirs.length}/{directions.length || "—"} {filtersOpen ? "▴" : "▾"}
          </button>
          {data?.ok && (
            <nav aria-label="跳转" className="ml-auto flex items-center gap-0.5">
              {navItems.map(([id, label, n]) => (
                <button
                  key={id}
                  type="button"
                  onClick={() => jump(id)}
                  className="h-7 rounded-[7px] px-2 text-[12.5px] font-medium text-role-system hover:bg-black/[0.05] hover:text-ink"
                >
                  {label}
                  {n != null && <span className="ml-1 tabular-nums">{n}</span>}
                </button>
              ))}
            </nav>
          )}
        </div>
        {filtersOpen && (
          <div className="mt-3 flex flex-wrap gap-2">
            {directions.map((d) => {
              const on = !dirs.length || dirs.includes(d.id);
              return (
                <button
                  key={d.id}
                  type="button"
                  aria-pressed={on}
                  onClick={() => toggleDir(d.id)}
                  className={cn(
                    "h-7 rounded-full border px-3 text-[12.5px] font-medium transition-colors",
                    on
                      ? "border-honey bg-honey/12 text-honey"
                      : "border-black/12 text-role-system hover:bg-black/[0.04]",
                  )}
                >
                  {d.title}
                </button>
              );
            })}
          </div>
        )}
      </div>

      <div
        ref={scrollRef}
        className="@container min-h-0 flex-1 overflow-auto overscroll-contain px-5 pb-6 pt-5"
      >
        {q.isPending && !data ? (
          <p className="py-6 text-center text-[13px] text-role-system">分析中…</p>
        ) : null}
        {q.isError && !data ? (
          <p className="py-6 text-center text-[13px] text-mine-loss">
            分析失败 · {String(q.error)}
          </p>
        ) : null}
        {data?.ok ? (
          <>
            <Verdict data={data} onJump={jump} />
            <Losses data={data} onTurn={toggleTurn} onAck={onAck} />
            <Timeline data={data} openTurn={openTurn} onToggleTurn={toggleTurn} />
            <Ledger data={data} />
          </>
        ) : null}
        {data && !data.ok ? (
          <p className="py-6 text-center text-[13px] text-mine-loss">
            分析失败{data.error ? ` · ${data.error}` : ""}
          </p>
        ) : null}
      </div>
    </div>
  );
}
