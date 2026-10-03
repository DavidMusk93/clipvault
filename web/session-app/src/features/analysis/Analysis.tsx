import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { ackFinding, getMine, type Mine, type MineFinding } from "../../api/mine";
import { Ledger } from "./Ledger";
import { Losses } from "./Losses";
import { mineDraftMarkdown } from "./lib";
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

const chip = (on: boolean) =>
  `h-6 shrink-0 rounded-full border px-2 text-[11.5px] font-semibold transition-colors ${
    on ? "border-honey bg-honey/12 text-honey" : "border-black/15 text-ink hover:bg-black/5"
  }`;

/**
 * 「分析」sheet — rebuilt from the taste (docs/design-taste.md 「分析」), not from
 * the vanilla markup: ① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本, semantic
 * colour, golden-ratio verdict, incremental refresh. Charts are ECharts.
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
  const [copyLabel, setCopyLabel] = useState("复制 AGENTS 草稿");
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
    el.classList.add("is-hit");
    window.setTimeout(() => el.classList.remove("is-hit"), 1200);
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
      window.setTimeout(() => setCopyLabel("复制 AGENTS 草稿"), 1200);
    } catch {
      /* clipboard unavailable */
    }
  };

  const summary = useMemo(() => {
    if (!data?.ok) return null;
    const w = data.window || {};
    const s = data.summary || {};
    return (
      <p className="mb-1.5 text-[12px] tabular-nums text-role-system">
        {String(w.from || "?")} → {String(w.to || "?")} · {s.n_turns || 0} 回合 · {s.n_tools || 0}{" "}
        工具
        {w.instances?.length ? ` · ${w.instances.join("/")}` : ""}
        {w.truncated ? (
          <span className="ml-1.5 rounded-full bg-mine-loss/12 px-1.5 text-[11px] font-semibold text-mine-loss">
            12000 行截断
          </span>
        ) : null}
        {data.baseline?.source ? (
          <span className="ml-1.5 rounded-full bg-black/[0.06] px-1.5 text-[11px] text-role-system">
            对照 {data.baseline.source}
          </span>
        ) : null}
        {!s.usage_turns ? (
          <span className="ml-1.5 rounded-full bg-mine-money/12 px-1.5 text-[11px] text-mine-money">
            无计费数据
          </span>
        ) : null}
      </p>
    );
  }, [data]);

  return (
    <div className="absolute inset-x-2 bottom-[52px] top-2 z-10 flex min-h-0 flex-col overflow-hidden rounded-2xl border border-black/10 bg-[#fafafa] shadow-[0_16px_48px_rgba(0,0,0,0.16)]">
      <div className="flex-none rounded-t-2xl border-b border-black/5 bg-white px-3.5 pb-2 pt-2.5">
        <div className="mb-1.5 flex items-center gap-2">
          <h2 className="flex-1 text-[16px] font-semibold tracking-[-0.02em] text-ink">会话分析</h2>
          <button
            type="button"
            onClick={() => void copyDraft()}
            className="h-7 rounded-lg border border-black/10 bg-white px-2 text-[11.5px] font-semibold text-ink hover:bg-black/5"
          >
            {copyLabel}
          </button>
          <button
            type="button"
            onClick={onClose}
            className="h-7 rounded-lg border border-black/10 bg-white px-2 text-[11.5px] font-semibold text-ink hover:bg-black/5"
          >
            关闭
          </button>
        </div>
        {summary}
        <div className="flex flex-wrap gap-1.5">
          {(["session", "recent"] as const).map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => {
                setScope(s);
                persist(s, dirs);
              }}
              className={chip(scope === s)}
            >
              {s === "session" ? "当前会话" : "最近 7 天"}
            </button>
          ))}
          {directions.map((d) => (
            <button
              key={d.id}
              type="button"
              onClick={() => toggleDir(d.id)}
              className={chip(!dirs.length || dirs.includes(d.id))}
            >
              {d.title}
            </button>
          ))}
        </div>
      </div>

      <div
        ref={scrollRef}
        className="min-h-0 flex-1 overflow-auto overscroll-contain px-3.5 py-2.5"
      >
        {q.isPending && !data ? <p className="text-[11.5px] text-role-system">分析中…</p> : null}
        {q.isError && !data ? (
          <p className="text-[11.5px] text-mine-loss">分析失败 · {String(q.error)}</p>
        ) : null}
        {data?.ok ? (
          <>
            <nav className="mb-2.5 flex flex-wrap gap-1.5">
              {[
                ["mineLosses", `损耗 ${findings.length}`],
                ...(data.turns?.length
                  ? ([["mineTimeline", `回合 ${data.turns.length}`]] as const)
                  : []),
                ["mineLedger", `账本 ${Object.keys(data.blocks || {}).length}`],
              ].map(([id, label]) => (
                <button
                  key={id}
                  type="button"
                  onClick={() => jump(id)}
                  className="h-6 rounded-full bg-black/[0.05] px-2.5 text-[11.5px] font-medium text-ink hover:bg-black/10"
                >
                  {label}
                </button>
              ))}
            </nav>
            <Verdict data={data} />
            <Losses data={data} onTurn={toggleTurn} onAck={onAck} />
            <Timeline data={data} openTurn={openTurn} onToggleTurn={toggleTurn} />
            <Ledger data={data} />
          </>
        ) : null}
        {data && !data.ok ? (
          <p className="text-[11.5px] text-mine-loss">
            分析失败{data.error ? ` · ${data.error}` : ""}
          </p>
        ) : null}
      </div>
    </div>
  );
}
