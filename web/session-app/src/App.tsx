import * as Tabs from "@radix-ui/react-tabs";
import { useQuery } from "@tanstack/react-query";
import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { api, type EventStubT, type SessionT } from "./api/client";
import { cn } from "./lib/cn";

const Analysis = lazy(() => import("./features/analysis/Analysis"));

type Role = "user" | "assistant" | "tool" | "ask" | "system";

const ROLE_COLOR: Record<Role, string> = {
  user: "text-role-user",
  assistant: "text-role-assistant",
  tool: "text-role-tool",
  ask: "text-role-ask",
  system: "text-role-system",
};

function roleOf(e: EventStubT): Role {
  if (e.hook_event === "UserPromptSubmit") return "user";
  if (e.hook_event === "Stop") return "assistant";
  if (e.hook_event === "PreToolUse" || e.hook_event === "PostToolUse") return "tool";
  if (e.hook_event === "Notification") return "ask";
  return "system";
}

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

function preview(e: EventStubT): string {
  const s = e.prompt || e.last_assistant_message || e.tool_name || e.llm_tool_name || "";
  return s.trim().split("\n")[0].slice(0, 120);
}

function Sessions() {
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: () => api.sessions(80) });
  const [selected, setSelected] = useState<string | null>(null);

  useEffect(() => {
    const first = sessions.data?.sessions?.[0];
    if (!selected && first) setSelected(first.session_id);
  }, [sessions.data, selected]);

  const events = useQuery({
    queryKey: ["events", selected],
    queryFn: () => api.events(selected as string),
    enabled: !!selected,
  });
  const rows = useMemo(() => events.data?.events ?? [], [events.data]);

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

      <main className="min-h-0 overflow-y-auto p-3">
        {!selected && <p className="text-[12px] text-role-system">选择左侧会话</p>}
        {events.isPending && selected && <p className="text-[12px] text-role-system">加载事件…</p>}
        {rows.map((e) => {
          const role = roleOf(e);
          return (
            <div key={e.event_id} className="mb-2 rounded-lg bg-white px-3 py-2 shadow-sm">
              <div className="mb-0.5 flex items-center gap-2">
                <span className={cn("text-[10px] font-semibold", ROLE_COLOR[role])}>{role}</span>
                <span className="text-[10px] text-role-system">{e.hook_event}</span>
                <span className="ml-auto text-[10px] text-role-system">{relTime(e.ts)}</span>
              </div>
              <div className="whitespace-pre-wrap break-words text-[12px] text-ink">
                {preview(e) || "—"}
              </div>
            </div>
          );
        })}
      </main>
    </div>
  );
}

export function App() {
  const health = useQuery({ queryKey: ["health"], queryFn: api.health, refetchInterval: 15000 });

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
