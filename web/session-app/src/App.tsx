import * as Tabs from "@radix-ui/react-tabs";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { lazy, Suspense, useEffect, useState } from "react";
import { api, type SessionT } from "./api/client";
import { SessionView } from "./features/session/SessionView";
import { cn } from "./lib/cn";

const Analysis = lazy(() => import("./features/analysis/Analysis"));

function relTime(ts?: string | null): string {
  if (!ts) return "—";
  const t = Date.parse(ts.replace(" ", "T") + (ts.endsWith("Z") ? "" : "Z"));
  if (Number.isNaN(t)) return ts.slice(0, 19);
  const d = Math.max(0, Date.now() - t) / 1000;
  if (d < 60) return "刚刚";
  if (d < 3600) return `${Math.floor(d / 60)} 分钟前`;
  if (d < 86400) return `${Math.floor(d / 3600)} 小时前`;
  return ts.slice(0, 10);
}

function Sessions() {
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: () => api.sessions(80) });
  const [selected, setSelected] = useState<string | null>(null);

  useEffect(() => {
    const first = sessions.data?.sessions?.[0];
    if (!selected && first) setSelected(first.session_id);
  }, [sessions.data, selected]);

  return (
    <div className="grid min-h-0 flex-1 grid-cols-[280px_1fr]">
      <aside className="min-h-0 overflow-y-auto border-r border-black/5 bg-white/50 p-2">
        {sessions.isPending && <p className="p-2 text-[12px] text-role-system">加载会话…</p>}
        {sessions.isError && <p className="p-2 text-[12px] text-mine-loss">会话列表加载失败</p>}
        {(sessions.data?.sessions ?? []).map((s: SessionT) => (
          <button
            type="button"
            key={s.session_id}
            onClick={() => setSelected(s.session_id)}
            className={cn(
              "mb-1 block w-full rounded-lg px-3 py-2 text-left",
              selected === s.session_id ? "bg-honey/10 ring-1 ring-honey/30" : "hover:bg-black/5",
            )}
          >
            <div className="truncate text-[12px] font-medium">
              {s.last_prompt?.trim().slice(0, 40) || s.session_id.slice(0, 10)}
            </div>
            <div className="mt-0.5 flex gap-2 text-[10px] text-role-system">
              <span>{s.instance_id || "—"}</span>
              <span>{s.event_count} 事件</span>
              <span>{relTime(s.last_ts)}</span>
            </div>
          </button>
        ))}
      </aside>

      <main className="min-h-0">
        {selected ? (
          <SessionView sessionId={selected} />
        ) : (
          <p className="p-3 text-[12px] text-role-system">选择左侧会话</p>
        )}
      </main>
    </div>
  );
}

export function App() {
  const health = useQuery({ queryKey: ["health"], queryFn: api.health, refetchInterval: 15000 });
  const qc = useQueryClient();

  // Parent ClipVault page handshake: it pauses/resumes the iframe with the
  // panel. On resume, refresh what is stale.
  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      const t = (e.data as { type?: string } | null)?.type;
      if (t === "clipvault-sessions-resume") void qc.invalidateQueries();
    };
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, [qc]);

  return (
    <Tabs.Root defaultValue="sessions" className="flex h-full flex-col">
      <header className="flex items-center gap-3 border-b border-black/5 bg-white/70 px-4 py-1.5 backdrop-blur">
        <span className="font-semibold text-[13px]">会话</span>
        <Tabs.List className="flex gap-1">
          <Tabs.Trigger
            value="sessions"
            className="rounded-md px-2 py-1 text-[12px] text-role-system data-[state=active]:bg-black/5 data-[state=active]:text-ink"
          >
            会话
          </Tabs.Trigger>
          <Tabs.Trigger
            value="analysis"
            className="rounded-md px-2 py-1 text-[12px] text-role-system data-[state=active]:bg-black/5 data-[state=active]:text-ink"
          >
            分析
          </Tabs.Trigger>
        </Tabs.List>
        <span className="text-[11px] text-role-system">
          {health.data
            ? `${health.data.events ?? 0} 条 · ${relTime(health.data.last_ts)}`
            : "加载中…"}
        </span>
        <span className="ml-auto text-[11px] text-role-system">
          {health.data?.backend_id ? `backend ${health.data.backend_id}` : ""}
        </span>
      </header>

      <Tabs.Content value="sessions" className="flex min-h-0 flex-1 flex-col outline-none">
        <Sessions />
      </Tabs.Content>
      <Tabs.Content value="analysis" className="min-h-0 flex-1 overflow-y-auto outline-none">
        <Suspense fallback={<p className="p-4 text-[12px] text-role-system">加载分析…</p>}>
          <Analysis />
        </Suspense>
      </Tabs.Content>
    </Tabs.Root>
  );
}
