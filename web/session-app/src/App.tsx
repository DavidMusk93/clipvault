import { localDateTime, relLocalTime } from "@render";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { api, type SessionT } from "./api/client";
import { RailCard, sourceLabel } from "./features/session/RailCard";
import { SessionView } from "./features/session/SessionView";

const Analysis = lazy(() => import("./features/analysis/Analysis"));

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

function Sessions({ onOpenAnalysis }: { onOpenAnalysis: () => void }) {
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: () => api.sessions(80) });
  const [selected, setSelected] = useState<string | null>(null);
  const [q, setQ] = useState("");

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
          <SessionView sessionId={selected} />
        ) : (
          <div className="thread" id="thread">
            <div className="empty">选择左侧会话</div>
          </div>
        )}
        <button type="button" className="cv-debug-fab cv-mine-fab" onClick={onOpenAnalysis}>
          分析
        </button>
      </section>
    </div>
  );
}

export function App() {
  const health = useQuery({ queryKey: ["health"], queryFn: api.health, refetchInterval: 15000 });
  const qc = useQueryClient();
  const [analysisOpen, setAnalysisOpen] = useState(false);

  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      const t = (e.data as { type?: string } | null)?.type;
      if (t === "clipvault-sessions-resume") void qc.invalidateQueries();
    };
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, [qc]);

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

      <Sessions onOpenAnalysis={() => setAnalysisOpen(true)} />

      <div className="cv-mine-sheet" hidden={!analysisOpen}>
        <div className="mine-head">
          <div className="mine-head-row">
            <h2>会话分析</h2>
            <button type="button" className="mine-x" onClick={() => setAnalysisOpen(false)}>
              关闭
            </button>
          </div>
        </div>
        <div className="mine-scroll">
          <Suspense fallback={<p className="mine-empty">加载分析…</p>}>
            {analysisOpen && <Analysis />}
          </Suspense>
        </div>
      </div>
    </>
  );
}
