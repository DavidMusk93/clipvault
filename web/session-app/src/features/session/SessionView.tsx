import { focusImRows, type ImRow, imMessagesFromEvents, layoutKey, renderRows } from "@render";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useMemo, useRef, useState } from "react";
import { api, type EventStubT, streamUrl } from "../../api/client";
import { bundleHtml, focusHtml } from "./render";

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

  // Display logic lives in web/session-render.mjs: chronological IM rows
  // (Pre/Post collapse, SessionStart drop), then beats vs bundled tool index.
  const imRows = useMemo<ImRow[]>(
    () =>
      imMessagesFromEvents([
        ...(beats.data?.events ?? []),
        ...(tools.data?.pages.flatMap((p) => p.events) ?? []),
        ...live,
      ]),
    [beats.data, tools.data, live],
  );
  const items = useMemo(() => focusImRows(imRows), [imRows]);
  const rowById = useMemo(
    () => new Map(imRows.map((r) => [String(r.event.event_id || ""), r])),
    [imRows],
  );

  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  useEffect(() => {
    setExpanded(new Set());
  }, [sessionId]);

  const parentRef = useRef<HTMLDivElement>(null);
  const virt = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 96,
    overscan: 8,
  });

  // Lazy: a bundle item's body renders on open; a raw JSON body fetches on open.
  useEffect(() => {
    const el = parentRef.current;
    if (!el) return;
    const onToggle = (ev: Event) => {
      const d = ev.target as HTMLDetailsElement;
      if (!d.matches) return;
      if (d.matches("details.history-item") && d.open) {
        const body = d.querySelector<HTMLElement>(".history-item-body");
        if (!body || body.dataset.loaded) return;
        const row = rowById.get(d.dataset.eid || "");
        if (!row) return;
        body.dataset.loaded = "1";
        body.innerHTML = renderRows([row], null);
      } else if (d.matches("details.raw") && d.open) {
        const host = d.querySelector<HTMLElement>(".raw-body");
        const id = d.closest(".bubble")?.getAttribute("data-id");
        if (!host || host.dataset.loaded || !id) return;
        host.dataset.loaded = "1";
        api
          .event(id)
          .then((j) => {
            const raw = (j.event as Record<string, unknown>).raw_json;
            host.textContent = (
              typeof raw === "string" ? raw : JSON.stringify(j.event, null, 2)
            ).slice(0, 12000);
          })
          .catch(() => {
            host.textContent = "加载失败";
          });
      }
    };
    const onClick = (ev: Event) => {
      const btn = (ev.target as HTMLElement | null)?.closest?.(".history-expand-all");
      if (!btn) return;
      const key = btn.closest("[data-key]")?.getAttribute("data-key");
      if (key) setExpanded((prev) => new Set(prev).add(key));
    };
    el.addEventListener("toggle", onToggle, true);
    el.addEventListener("click", onClick);
    return () => {
      el.removeEventListener("toggle", onToggle, true);
      el.removeEventListener("click", onClick);
    };
  }, [rowById]);

  const vitems = virt.getVirtualItems();
  const lastIndex = vitems.length ? vitems[vitems.length - 1].index : 0;
  useEffect(() => {
    if (lastIndex >= items.length - 8 && tools.hasNextPage && !tools.isFetchingNextPage) {
      void tools.fetchNextPage();
    }
  }, [lastIndex, items.length, tools.hasNextPage, tools.isFetchingNextPage, tools]);

  return (
    <div className="thread" id="thread" ref={parentRef} style={{ overflowY: "auto" }}>
      {items.length === 0 && (beats.isPending || tools.isPending) && (
        <div className="empty">加载事件…</div>
      )}
      {items.length === 0 && !beats.isPending && !tools.isPending && (
        <div className="empty">没有匹配事件</div>
      )}
      <div style={{ height: virt.getTotalSize(), position: "relative" }}>
        {vitems.map((vi) => {
          const it = items[vi.index];
          if (!it) return null;
          const prev = vi.index > 0 ? items[vi.index - 1] : null;
          const prevRow: ImRow | null = prev
            ? prev.type === "focus"
              ? prev.row
              : (prev.rows[prev.rows.length - 1] ?? null)
            : null;
          const key = layoutKey(it);
          const html =
            it.type === "focus" ? focusHtml(it, prevRow) : bundleHtml(it, expanded.has(key));
          return (
            <div
              key={key}
              data-key={key}
              data-index={vi.index}
              ref={virt.measureElement}
              className="thread-block"
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${vi.start}px)`,
              }}
              dangerouslySetInnerHTML={{ __html: html }}
            />
          );
        })}
      </div>
      {tools.isFetchingNextPage && <div className="empty">加载更多…</div>}
    </div>
  );
}
