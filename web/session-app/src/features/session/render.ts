import {
  bundleTitle,
  esc,
  type ImRow,
  type LayoutItem,
  localDateTime,
  renderRows,
  rowPreview,
} from "@render";

/** The bundle cap from the vanilla panel: earlier tools collapse behind 「查看全部」. */
export const BUNDLE_SHOW = 32;

type BundleItem = Extract<LayoutItem, { type: "bundle" }>;
type FocusItem = Extract<LayoutItem, { type: "focus" }>;

export function historyItemHtml(row: ImRow): string {
  const dt = localDateTime(row.event.ts);
  const pre = rowPreview(row);
  return `<details class="history-item" data-eid="${esc(row.event.event_id || "")}">
    <summary><span class="t">${esc(dt)}</span><span class="w">${esc(row.label)}</span><span class="p" title="${esc(pre)}">${esc(pre.slice(0, 80))}</span></summary>
    <div class="history-item-body"></div>
  </details>`;
}

export function bundleHtml(item: BundleItem, expandAll: boolean): string {
  const all = item.rows || [];
  const title = item.title || bundleTitle(all);
  const shown = expandAll || all.length <= BUNDLE_SHOW ? all : all.slice(-BUNDLE_SHOW);
  const items = shown.map(historyItemHtml).join("");
  return `<div class="row assistant"><details class="history-bundle"${expandAll ? " open" : ""}>
    <summary>${esc(title)}</summary>
    <div class="history-body"><button type="button" class="history-expand-all">查看全部</button>${items}</div>
  </details></div>`;
}

export function focusHtml(item: FocusItem, prev: ImRow | null): string {
  return renderRows([item.row], prev);
}
