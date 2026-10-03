import { localDateTime, relLocalTime } from "@render";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from "react";
import { api, type SessionT, streamUrl } from "./api/client";
import { RailCard, sourceLabel } from "./features/session/RailCard";
import { SessionView } from "./features/session/SessionView";
import { emit, flush, installTelemetry, mountMetricsPanel } from "./lib/telemetry";

const Analysis = lazy(() => import("./features/analysis/Analysis"));

/** Store timestamps are naive UTC; keep the patched card on the same clock. */
const utcNaiveNow = () => new Date().toISOString().slice(0, 19).replace("T", " ");

function sessionTitle(s: SessionT): string {
  const p = String(s.last_prompt || "")
    .trim()
    .split(/\n/)[0];
  if (p) return p.slice(0, 56);
  const cwd = String(s.cwd || "").replace(/\/$/, "");
  const base = cwd.split("/").filter(Boolean).pop();
  if (base) return base;
  const id = String(s.session_id || "");
  return id ? `${id.slice(0, 10)}…` : "无会话";
}

function SessionHead({ s }: { s: SessionT | null }) {
  const raw = String(s?.source || "")
    .trim()
    .toLowerCase();
  const cwd = String(s?.cwd || "").replace(/\/$/, "");
  const host = String(s?.instance_id || "").trim();
  return (
    <div className={`session-head${s ? "" : " is-empty"}`} id="sessionHead">
      <span className="sid" id="sessionSid" title={s?.session_id}>
        {s ? sessionTitle(s) : ""}
      </span>
      <span className="idline">
        <span id="sessionWhen">{s ? localDateTime(s.last_ts) : ""}</span>
        <span id="sessionSource">{raw ? `agent ${sourceLabel(raw)}` : ""}</span>
        <span id="sessionHost">{host}</span>
        <span className="cwd" id="sessionCwd" title={cwd}>
          {cwd}
        </span>
      </span>
    </div>
  );
}

/** `分析` FAB. Lives in the corner stack so it is styled and pinned like the
 *  vanilla panel; a bare button rendered as plain text before. */
function CornerStack({
  analysisOpen,
  onOpenAnalysis,
}: {
  analysisOpen: boolean;
  onOpenAnalysis: () => void;
}) {
  const metricsRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = metricsRef.current;
    if (!el) return;
    return mountMetricsPanel(el);
  }, []);
  return (
    <div className="cv-corner-stack">
      <div className="cv-mine-float">
        <button
          type="button"
          className={`cv-debug-fab cv-mine-fab${analysisOpen ? " is-on" : ""}`}
          onClick={onOpenAnalysis}
          aria-label="分析"
          aria-pressed={analysisOpen}
        >
          分析
        </button>
      </div>
      {/* 调试 float is imperative (metrics-panel.js); keep a React-owned slot so
          reconciliation never removes it. DOM order 分析 · 调试 puts 分析 on top,
          so from the bottom the stack reads 调试 · 分析 · ↓ (vanilla). */}
      <div className="cv-metrics-slot" ref={metricsRef} />
    </div>
  );
}

function Sessions({
  analysisOpen,
  paused,
  onOpenAnalysis,
  onCloseAnalysis,
}: {
  analysisOpen: boolean;
  paused: boolean;
  onOpenAnalysis: () => void;
  onCloseAnalysis: () => void;
}) {
  const sessions = useQuery({
    queryKey: ["sessions"],
    queryFn: () => api.sessions(80),
    refetchInterval: 60000,
  });
  const [selected, setSelected] = useState<string | null>(null);
  const [q, setQ] = useState("");

  // biome-ignore lint/correctness/useExhaustiveDependencies: refire on every successful refresh.
  useEffect(() => {
    if (sessions.isSuccess) {
      emit("trae_sessions_list", { value: (sessions.data?.sessions ?? []).length });
    }
  }, [sessions.isSuccess, sessions.dataUpdatedAt, sessions.data]);

  useEffect(() => {
    const first = sessions.data?.sessions?.[0];
    if (!selected && first) setSelected(first.session_id);
  }, [sessions.data, selected]);

  const rows = useMemo(() => {
    const list = sessions.data?.sessions ?? [];
    const needle = q.trim().toLowerCase();
    if (!needle) return list;
    return list.filter((s) =>
      `${s.last_prompt || ""} ${s.cwd || ""} ${s.instance_id || ""} ${s.source || ""}`
        .toLowerCase()
        .includes(needle),
    );
  }, [sessions.data, q]);

  const current = rows.find((s) => s.session_id === selected) ?? null;

  const pin = async (id: string, pinned: boolean) => {
    try {
      await fetch(`/trae/api/sessions/pin`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_id: id, pinned }),
      });
    } catch {
      /* ignore */
    }
    await sessions.refetch();
  };
  const copy = (id: string) => {
    void navigator.clipboard?.writeText(id);
  };

  return (
    <div className="app">
      <aside className="rail">
        <div className="rail-search">
          <input
            type="search"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="搜 prompt / 工具"
          />
        </div>
        <div id="sessionList">
          {sessions.isPending && <div className="empty">加载会话…</div>}
          {sessions.isError && <div className="empty">会话列表加载失败</div>}
          {!sessions.isPending && rows.length === 0 && <div className="empty">暂无会话</div>}
          {rows.map((s) => (
            <RailCard
              key={s.session_id}
              s={s}
              active={s.session_id === selected}
              onSelect={setSelected}
              onPin={pin}
              onCopy={copy}
            />
          ))}
        </div>
      </aside>

      <section className="stage">
        <SessionHead s={current} />
        {selected ? (
          <SessionView sessionId={selected} paused={paused} />
        ) : (
          <div className="thread" id="thread">
            <div className="empty">选择左侧会话</div>
          </div>
        )}
        <CornerStack analysisOpen={analysisOpen} onOpenAnalysis={onOpenAnalysis} />

        {/* Sheet covers the thread, not the rail: it belongs to .stage (vanilla
            appended it to .stage too). Analysis renders the .cv-mine-sheet itself
            so it can own the is-updating / is-pending state. */}
        {analysisOpen && (
          <Suspense
            fallback={
              <div className="cv-mine-sheet">
                <p className="mine-empty">加载分析…</p>
              </div>
            }
          >
            <Analysis sessionId={current?.session_id ?? ""} onClose={onCloseAnalysis} />
          </Suspense>
        )}
      </section>
    </div>
  );
}

export function App() {
  const health = useQuery({
    queryKey: ["health"],
    queryFn: api.health,
    refetchInterval: 60000,
  });
  const qc = useQueryClient();
  const [analysisOpen, setAnalysisOpen] = useState(false);
  const [paused, setPaused] = useState(false);

  useEffect(() => {
    installTelemetry();
    emit("trae_sessions_boot", { value: 1 });
  }, []);

  // Live rail, incremental: a hook event patches the matching card in place
  // (count / last_ts / prompt) instead of refetching the whole list. A full
  // refetch is coalesced only when a session we don't know about appears.
  useEffect(() => {
    if (paused) return;
    const es = new EventSource(streamUrl());
    let timer = 0;
    const refetchSoon = () => {
      if (timer) return;
      timer = window.setTimeout(() => {
        timer = 0;
        void qc.invalidateQueries({ queryKey: ["sessions"] });
      }, 3000);
    };
    es.onmessage = (ev) => {
      let d: { type?: string; session_id?: string; hook_event?: string; preview?: string } | null =
        null;
      try {
        d = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (d?.type !== "hook_event" || !d.session_id) return;
      const sid = d.session_id;
      const ts = utcNaiveNow();
      let known = false;
      qc.setQueryData<{ sessions: SessionT[] }>(["sessions"], (old) => {
        if (!old?.sessions) return old;
        const i = old.sessions.findIndex((s) => s.session_id === sid);
        if (i < 0) return old;
        known = true;
        const sessions = old.sessions.slice();
        const s = { ...sessions[i] };
        s.event_count = (s.event_count ?? 0) + 1;
        s.last_ts = ts;
        if (d?.hook_event === "UserPromptSubmit" && d.preview) s.last_prompt = d.preview;
        sessions[i] = s;
        return { ...old, sessions };
      });
      qc.setQueryData<{ events?: number; last_ts?: string }>(["health"], (old) =>
        old ? { ...old, events: (old.events ?? 0) + 1, last_ts: ts } : old,
      );
      if (!known) refetchSoon();
    };
    return () => {
      if (timer) window.clearTimeout(timer);
      es.close();
    };
  }, [qc, paused]);

  useEffect(() => {
    // The parent shell hides its own close button while the analysis sheet
    // covers the thread. Vanilla posted this contract; without it the close
    // button floats on top of the sheet.
    const post = () => {
      if (window.parent === window) return;
      try {
        window.parent.postMessage(
          { type: "clipvault-sessions-overlay", open: analysisOpen },
          location.origin,
        );
      } catch {
        /* not embedded */
      }
    };
    post();
    const onMsg = (e: MessageEvent) => {
      const t = (e.data as { type?: string } | null)?.type;
      if (t === "clipvault-sessions-resume") {
        setPaused(false);
        void qc.invalidateQueries();
        post();
      } else if (t === "clipvault-sessions-pause") {
        // Panel closed: stop the streams and flush what is queued.
        setPaused(true);
        flush();
      } else if (t === "clipvault-sessions-settled") {
        emit("trae_sessions_layout", { payload: { phase: "settled", kind: "parent" } });
      }
    };
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, [analysisOpen, qc]);

  return (
    <>
      <header className="top">
        <div>
          <h1>会话</h1>
          <div className="sub" id="health">
            {health.data
              ? `${health.data.events ?? 0} 条 · ${relLocalTime(health.data.last_ts)}`
              : "加载中…"}
          </div>
        </div>
        <div className="grow" />
        <a className="back" href="http://127.0.0.1:8080/">
          回剪贴板
        </a>
      </header>

      <Sessions
        analysisOpen={analysisOpen}
        paused={paused}
        onOpenAnalysis={() => setAnalysisOpen(true)}
        onCloseAnalysis={() => setAnalysisOpen(false)}
      />
    </>
  );
}
