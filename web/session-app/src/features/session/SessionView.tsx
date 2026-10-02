import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useMemo, useRef, useState } from "react";
import { api, type EventStubT, streamUrl } from "../../api/client";
import { cn } from "../../lib/cn";

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
  return s.trim().split("\n")[0].slice(0, 140);
}

/** Lazy body: the stub is already in the list; the full bundle is fetched only
 *  when the row is opened. */
function LazyBody({ id }: { id: string }) {
  const [open, setOpen] = useState(false);
  const q = useQuery({
    queryKey: ["event", id],
    queryFn: () => api.event(id),
    enabled: open,
    staleTime: 5 * 60_000,
  });
  const raw = q.data?.event?.raw_json;
  const text = typeof raw === "string" ? raw : q.data ? JSON.stringify(q.data.event, null, 2) : "";
  return (
    <details className="mt-1" onToggle={(e) => setOpen((e.target as HTMLDetailsElement).open)}>
      <summary className="cursor-pointer text-[10px] text-role-tool">正文</summary>
      <pre className="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded bg-black/[0.03] p-2 text-[11px]">
        {q.isPending ? "加载中…" : text.slice(0, 12000)}
      </pre>
    </details>
  );
}

function Row({ e }: { e: EventStubT }) {
  const role = roleOf(e);
  const isTool = role === "tool";
  return (
    <div className="mb-2 rounded-lg bg-white px-3 py-2 shadow-sm">
      <div className="mb-0.5 flex items-center gap-2">
        <span className={cn("text-[10px] font-semibold", ROLE_COLOR[role])}>{role}</span>
        <span className="text-[10px] text-role-system">{e.hook_event}</span>
        <span className="ml-auto text-[10px] text-role-system">{relTime(e.ts)}</span>
      </div>
      <div className="whitespace-pre-wrap break-words text-[12px] text-ink">
        {preview(e) || "—"}
      </div>
      {isTool && <LazyBody id={e.event_id} />}
    </div>
  );
}

export function SessionView({ sessionId }: { sessionId: string }) {
  const beats = useQuery({
    queryKey: ["beats", sessionId],
    queryFn: () => api.beats(sessionId),
    staleTime: 30_000,
  });
  const tools = useInfiniteQuery({
    queryKey: ["tools", sessionId],
    queryFn: ({ pageParam }) => api.eventsPaged(sessionId, pageParam),
    initialPageParam: null as { ts: string; event_id: string } | null,
    getNextPageParam: (last) => (last.has_more ? (last.next_cursor ?? undefined) : undefined),
    staleTime: 30_000,
  });

  const [live, setLive] = useState<EventStubT[]>([]);
  useEffect(() => {
    setLive([]);
    if (!sessionId) return;
    const es = new EventSource(streamUrl());
    es.onmessage = (ev) => {
      try {
        const d = JSON.parse(ev.data) as EventStubT & { type?: string };
        if (d.type === "hook_event" && d.session_id === sessionId && d.event_id) {
          setLive((prev) => (prev.some((x) => x.event_id === d.event_id) ? prev : [...prev, d]));
        }
      } catch {
        /* ping / connected */
      }
    };
    return () => es.close();
  }, [sessionId]);

  const items = useMemo(() => {
    const stubs = tools.data?.pages.flatMap((p) => p.events) ?? [];
    // Drop PreToolUse when its Post is loaded (may be on a later page).
    const posted = new Set(
      stubs
        .filter((s) => s.hook_event === "PostToolUse" && s.tool_use_id)
        .map((s) => s.tool_use_id as string),
    );
    const deduped = stubs.filter(
      (s) => !(s.hook_event === "PreToolUse" && s.tool_use_id && posted.has(s.tool_use_id ?? "")),
    );
    const all = [...(beats.data?.events ?? []), ...deduped, ...live];
    all.sort((a, b) => a.ts.localeCompare(b.ts) || a.event_id.localeCompare(b.event_id));
    return all;
  }, [beats.data, tools.data, live]);

  const parentRef = useRef<HTMLDivElement>(null);
  const virt = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 76,
    overscan: 12,
  });
  const vitems = virt.getVirtualItems();
  const lastIndex = vitems.length ? vitems[vitems.length - 1].index : 0;

  useEffect(() => {
    if (lastIndex >= items.length - 12 && tools.hasNextPage && !tools.isFetchingNextPage) {
      void tools.fetchNextPage();
    }
  }, [lastIndex, items.length, tools.hasNextPage, tools.isFetchingNextPage, tools]);

  return (
    <div ref={parentRef} className="h-full overflow-y-auto p-3">
      {items.length === 0 && tools.isPending && (
        <p className="text-[12px] text-role-system">加载事件…</p>
      )}
      <div style={{ height: virt.getTotalSize(), position: "relative" }}>
        {vitems.map((vi) => {
          const e = items[vi.index];
          if (!e) return null;
          return (
            <div
              key={e.event_id}
              data-index={vi.index}
              ref={virt.measureElement}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${vi.start}px)`,
              }}
            >
              <Row e={e} />
            </div>
          );
        })}
      </div>
      {tools.isFetchingNextPage && (
        <p className="py-2 text-center text-[11px] text-role-system">加载更多…</p>
      )}
    </div>
  );
}
