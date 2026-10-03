import {
  mineBodyHtml,
  mineDataSig,
  mineDirectionsHtml,
  mineDraftMarkdown,
  mineSummaryHtml,
} from "@mine";
import type { MouseEvent as ReactMouseEvent } from "react";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { getMine, type Mine } from "../../api/mine";
import { mountMineCharts } from "../../lib/echarts";

/**
 * 「分析」sheet. The four sections (① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 →
 * ④ 账本) are rendered by the SHARED display logic in `web/mine-render.mjs`
 * (aliased `@mine`) — the same HTML the vanilla panel produced, so the CSS in
 * `theme/panel.css` gives the same look. Do not fork a second implementation
 * (docs/design-web-frontend.md §5, docs/design-taste.md 「分析」).
 */

const MINE_KEY = "cv.trae.mine.v1";
const AUTO_MS = 5000;
const BASE =
  typeof location !== "undefined" && location.pathname.startsWith("/trae") ? "/trae" : "";

type Scope = "session" | "recent";
type Dir = { id: string; title: string };

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
  const [data, setData] = useState<Mine | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [pending, setPending] = useState(false);
  const [openTurn, setOpenTurn] = useState<number | null>(null);
  const [copyLabel, setCopyLabel] = useState("复制 AGENTS 草稿");

  const bodyRef = useRef<HTMLDivElement>(null);
  const sigRef = useRef("");
  const scrollRef = useRef(0);
  const loadingRef = useRef(false);
  const openTurnRef = useRef<number | null>(null);
  openTurnRef.current = openTurn;

  const directions: Dir[] = useMemo(() => {
    const d = (data as { directions?: Dir[] } | null)?.directions;
    return Array.isArray(d) ? d : [];
  }, [data]);

  const persist = useCallback((nextScope: Scope, nextDirs: string[]) => {
    try {
      localStorage.setItem(MINE_KEY, JSON.stringify({ scope: nextScope, dirs: nextDirs }));
    } catch {
      /* ignore */
    }
  }, []);

  const load = useCallback(
    async ({ auto = false }: { auto?: boolean } = {}) => {
      if (loadingRef.current) return;
      loadingRef.current = true;
      let updTimer = 0;
      if (auto) {
        // Surface the pill only when the round-trip is slow; avoids flicker.
        updTimer = window.setTimeout(() => setUpdating(true), 500);
      } else {
        setPending(false);
        setError("");
        setLoading(true);
      }
      try {
        const d = await getMine(scope, dirs, !auto, sessionId);
        const sig = mineDataSig(d);
        if (auto && sig === sigRef.current) return;
        sigRef.current = sig;
        scrollRef.current = auto ? (bodyRef.current?.scrollTop ?? 0) : 0;
        setData(d);
        setError("");
      } catch (err) {
        if (!auto) setError(String((err as Error)?.message || err));
      } finally {
        loadingRef.current = false;
        if (updTimer) window.clearTimeout(updTimer);
        setUpdating(false);
        setLoading(false);
      }
    },
    [scope, dirs, sessionId],
  );

  useEffect(() => {
    void load({ auto: false });
  }, [load]);

  // Coalesced auto refresh: at most one recompute per AUTO_MS while the sheet is
  // open. If a turn detail is expanded, mark stale instead of repainting.
  useEffect(() => {
    const t = window.setInterval(() => {
      if (openTurnRef.current !== null) {
        setPending(true);
        return;
      }
      void load({ auto: true });
    }, AUTO_MS);
    return () => window.clearInterval(t);
  }, [load]);

  const bodyHtml = useMemo(() => (data ? mineBodyHtml(data, { openTurn }) : ""), [data, openTurn]);
  const summaryHtml = useMemo(() => (data ? mineSummaryHtml(data) : ""), [data]);
  const dirsHtml = useMemo(() => mineDirectionsHtml(directions, dirs), [directions, dirs]);

  // Restore the reading position across a repaint (auto refresh / turn toggle).
  // biome-ignore lint/correctness/useExhaustiveDependencies: re-restore when the rendered HTML changes.
  useLayoutEffect(() => {
    const el = bodyRef.current;
    if (el) el.scrollTop = scrollRef.current;
  }, [bodyHtml]);

  const jumpTo = (id: string) => {
    const el = bodyRef.current?.querySelector(`[id="${id}"]`);
    if (!el) return;
    el.scrollIntoView({ block: "start" });
    el.classList.add("is-hit");
    window.setTimeout(() => el.classList.remove("is-hit"), 1200);
  };

  const toggleTurn = (n: number) => {
    const next = openTurnRef.current === n ? null : n;
    scrollRef.current = bodyRef.current?.scrollTop ?? 0;
    setOpenTurn(next);
    requestAnimationFrame(() => {
      bodyRef.current?.querySelector(`#turn-${n}`)?.scrollIntoView({ block: "center" });
      if (next === null && pending) {
        setPending(false);
        void load({ auto: true });
      }
    });
  };

  // Mount ECharts into the shared renderer's `.mc-echart` placeholders. Re-run
  // whenever the body HTML changes (turn toggle / refresh) and dispose first.
  const chartsDispose = useRef<(() => void) | null>(null);
  // biome-ignore lint/correctness/useExhaustiveDependencies: the click handler reads the current turn/jump closures.
  useEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    let cancelled = false;
    chartsDispose.current?.();
    chartsDispose.current = null;
    void mountMineCharts(el, (jump) => {
      if (typeof jump === "number") toggleTurn(jump);
      else jumpTo(String(jump));
    }).then((dispose) => {
      if (cancelled) dispose();
      else chartsDispose.current = dispose;
    });
    return () => {
      cancelled = true;
    };
  }, [bodyHtml]);

  useEffect(() => () => chartsDispose.current?.(), []);

  const ack = async (btn: HTMLElement) => {
    const fid = btn.getAttribute("data-ack") || "";
    const status = btn.getAttribute("data-ack-status") || "";
    const found = (
      (data?.findings as {
        id: string;
        metric?: { id?: string; now?: unknown; target?: unknown };
      }[]) || []
    ).find((x) => String(x.id) === fid);
    const m = found?.metric || {};
    const label = btn.textContent || "";
    btn.textContent = "记录中…";
    try {
      const res = await fetch(`${BASE}/api/mine/ack`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          scope,
          session_id: scope === "session" ? sessionId : "",
          finding_id: fid,
          status,
          metric: { id: m.id || "", now: m.now ?? null, target: m.target ?? null },
        }),
      });
      if (!res.ok) throw new Error(`ack ${res.status}`);
      await load({ auto: false });
    } catch {
      btn.textContent = "失败";
      window.setTimeout(() => {
        btn.textContent = label;
      }, 1500);
    }
  };

  const onClick = (ev: ReactMouseEvent<HTMLElement>) => {
    const t = ev.target as HTMLElement;
    const jump = t.closest("[data-jump]");
    if (jump) {
      jumpTo(jump.getAttribute("data-jump") || "");
      return;
    }
    const turnBtn = t.closest("[data-mine-turn]");
    if (turnBtn) {
      toggleTurn(Number(turnBtn.getAttribute("data-mine-turn")));
      return;
    }
    const refBtn = t.closest("[data-turn]");
    if (refBtn) {
      toggleTurn(Number(refBtn.getAttribute("data-turn")));
      return;
    }
    const ackBtn = t.closest("[data-ack]");
    if (ackBtn) {
      ev.preventDefault();
      ev.stopPropagation();
      void ack(ackBtn as HTMLElement);
      return;
    }
    const scopeBtn = t.closest("[data-scope]");
    if (scopeBtn) {
      const next = (scopeBtn.getAttribute("data-scope") as Scope) || "session";
      setOpenTurn(null);
      setScope(next);
      persist(next, dirs);
      return;
    }
    const dirBtn = t.closest("[data-dir]");
    if (dirBtn) {
      const id = dirBtn.getAttribute("data-dir") || "";
      const base = dirs.length ? dirs.slice() : directions.map((d) => d.id);
      const i = base.indexOf(id);
      if (i >= 0) base.splice(i, 1);
      else base.push(id);
      setOpenTurn(null);
      setDirs(base);
      persist(scope, base);
    }
  };

  const sheetRef = useRef<HTMLDivElement>(null);
  const onClickRef = useRef(onClick);
  onClickRef.current = onClick;

  // Delegated clicks (jump / turn / ref / ack / scope / dir). A native listener
  // keeps the container a plain div, like the thread's own delegation.
  useEffect(() => {
    const el = sheetRef.current;
    if (!el) return;
    const handler = (ev: Event) =>
      onClickRef.current(ev as unknown as ReactMouseEvent<HTMLElement>);
    el.addEventListener("click", handler);
    return () => el.removeEventListener("click", handler);
  }, []);

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

  return (
    <div
      ref={sheetRef}
      className={`cv-mine-sheet${updating ? " is-updating" : ""}${pending ? " is-pending" : ""}`}
    >
      <div className="mine-head">
        <div className="mine-head-row">
          <h2>会话分析</h2>
          <button
            type="button"
            className="mine-copy"
            onClick={(e) => {
              e.stopPropagation();
              void copyDraft();
            }}
          >
            {copyLabel}
          </button>
          <button
            type="button"
            className="mine-x"
            onClick={(e) => {
              e.stopPropagation();
              onClose();
            }}
          >
            关闭
          </button>
        </div>
        {summaryHtml ? (
          // biome-ignore lint/security/noDangerouslySetInnerHtml: escaped string builders in @mine.
          <p className="mine-sum" dangerouslySetInnerHTML={{ __html: summaryHtml }} />
        ) : null}
        <div className="mine-scopes">
          <button
            type="button"
            className={`mine-chip${scope === "session" ? " is-on" : ""}`}
            data-scope="session"
          >
            当前会话
          </button>
          <button
            type="button"
            className={`mine-chip${scope === "recent" ? " is-on" : ""}`}
            data-scope="recent"
          >
            最近 7 天
          </button>
        </div>
        {/* biome-ignore lint/security/noDangerouslySetInnerHtml: escaped string builders in @mine. */}
        <div className="mine-dirs" dangerouslySetInnerHTML={{ __html: dirsHtml }} />
      </div>
      <div className="mine-scroll" ref={bodyRef}>
        {loading && !data ? <p className="mine-empty">分析中…</p> : null}
        {error && !loading ? <p className="mine-empty">分析失败 · {error}</p> : null}
        {data ? (
          // biome-ignore lint/security/noDangerouslySetInnerHtml: escaped string builders in @mine.
          <div dangerouslySetInnerHTML={{ __html: bodyHtml }} />
        ) : null}
      </div>
    </div>
  );
}
