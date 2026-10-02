import { focusImRows, type ImRow, imMessagesFromEvents, layoutKey, renderRows } from "@render";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, type EventStubT, streamUrl } from "../../api/client";
import { cn } from "../../lib/cn";
import { ENGINES } from "./engines";
import { bundleHtml, focusHtml } from "./render";

const NEAR = 64;

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
  // biome-ignore lint/correctness/useExhaustiveDependencies: reset expansion when the session changes.
  useEffect(() => {
    setExpanded(new Set());
  }, [sessionId]);

  const parentRef = useRef<HTMLDivElement>(null);
  const virt = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    // Key rows by layout identity, not index. The tool index is paged in, so
    // older rows are prepended; with index keys the virtualizer hands a row's
    // measured height to a different row and the blocks overlap.
    getItemKey: (index) => layoutKey(items[index]),
    estimateSize: () => 96,
    overscan: 8,
  });

  // Follow-to-latest (taste: 跟底). New rows pin to the bottom unless the user
  // scrolled up; then the ↓ button surfaces with an unread tint.
  const [followTail, setFollowTail] = useState(true);
  const [pendingNew, setPendingNew] = useState(false);
  const prevCount = useRef(0);
  const total = virt.getTotalSize();

  const pinBottom = useCallback(() => {
    const el = parentRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, []);

  useEffect(() => {
    const el = parentRef.current;
    if (!el) return;
    let lastTop = el.scrollTop;
    const onScroll = () => {
      const top = el.scrollTop;
      const near = el.scrollHeight - top - el.clientHeight <= NEAR;
      if (near) {
        setFollowTail(true);
        setPendingNew(false);
      } else if (top < lastTop - 2) {
        // Only a genuine upward scroll stops following; programmatic pins and
        // late measurement growth also fire scroll events but move down.
        setFollowTail(false);
      }
      lastTop = top;
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  // biome-ignore lint/correctness/useExhaustiveDependencies: re-pin when rows grow or their measured height changes.
  useEffect(() => {
    if (followTail) pinBottom();
  }, [followTail, items.length, total, pinBottom]);

  useEffect(() => {
    if (!followTail && items.length > prevCount.current) setPendingNew(true);
    prevCount.current = items.length;
  }, [items.length, followTail]);

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
        const pack = d.closest(".history-body");
        if (pack && pack.getAttribute("data-expand-all") !== "1") {
          // Accordion: one open item per bundle (taste).
          for (const other of pack.querySelectorAll<HTMLDetailsElement>(
            ":scope > details.history-item",
          )) {
            if (other !== d && other.open) other.open = false;
          }
        }
        const eid = d.dataset.eid || "";
        const row = rowById.get(eid);
        const slim =
          row?.role === "tool" && row.event.tool_input == null && row.event.tool_response == null;
        const show = (r: ImRow | null) => {
          body.dataset.loaded = "1";
          if (!r) {
            body.innerHTML = '<div class="empty">这条还不在当前窗口，请点「查看全部」或刷新</div>';
            return;
          }
          body.innerHTML = renderRows(
            [r],
            { event: r.event, role: "__" } as unknown as ImRow,
            ENGINES,
          );
        };
        // The events list ships tool stubs without tool_input/tool_response;
        // fetch the full event for the body (vanilla did the same).
        if (row && !slim) {
          show(row);
          return;
        }
        api
          .event(eid)
          .then((j) => show(imMessagesFromEvents([j.event])[0] ?? null))
          .catch((err) => {
            body.textContent = String(err);
          });
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
      const block = btn.closest("[data-key]") as HTMLElement | null;
      const key = block?.getAttribute("data-key");
      if (!key || !block) return;
      setExpanded((prev) => new Set(prev).add(key));
      // 「查看全部」opens every item once, so their bodies lazy-load. The flag
      // suppresses the per-item accordion for the burst of toggle events.
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          // Re-query: the bundle block's innerHTML was replaced by the re-render.
          const host = block.querySelector(".history-body");
          host?.setAttribute("data-expand-all", "1");
          block.querySelectorAll<HTMLDetailsElement>("details.history-item").forEach((d) => {
            d.open = true;
          });
          window.setTimeout(() => host?.removeAttribute("data-expand-all"), 400);
        });
      });
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
    <>
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
              it.type === "focus"
                ? focusHtml(it, prevRow, ENGINES)
                : bundleHtml(it, expanded.has(key));
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
                // biome-ignore lint/security/noDangerouslySetInnerHtml: html is produced by the shared session-render logic and sanitized there.
                dangerouslySetInnerHTML={{ __html: html }}
              />
            );
          })}
        </div>
        {tools.isFetchingNextPage && <div className="empty">加载更多…</div>}
      </div>
      <button
        type="button"
        className={cn("follow", pendingNew && "has-new")}
        hidden={followTail}
        title="回到最新"
        aria-label="回到最新并跟踪"
        onClick={() => {
          setFollowTail(true);
          setPendingNew(false);
          pinBottom();
        }}
      >
        ↓
      </button>
    </>
  );
}
