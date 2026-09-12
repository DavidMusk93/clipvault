/** Window math for notes preview. No React — tests import this directly. */

export const PREVIEW_EST_H = 72;
export const PREVIEW_OVERSCAN = 12;
export const PREVIEW_WINDOW_MIN = 48;

export function previewWindow(scrollTop, viewH, n, heights, est = PREVIEW_EST_H, overscan = PREVIEW_OVERSCAN) {
  const count = Math.max(0, n | 0);
  if (count <= 0) return { from: 0, to: 0, padTop: 0, padBottom: 0, total: 0 };
  const hs = heights || [];
  const hAt = (i) => {
    const v = Number(hs[i]);
    return Number.isFinite(v) && v > 0 ? v : est;
  };
  const tops = new Array(count);
  let y = 0;
  for (let i = 0; i < count; i++) {
    tops[i] = y;
    y += hAt(i);
  }
  const total = y;
  if (count <= PREVIEW_WINDOW_MIN) {
    return { from: 0, to: count, padTop: 0, padBottom: 0, total };
  }
  const viewTop = Math.max(0, Number(scrollTop) || 0);
  const viewBot = viewTop + Math.max(1, Number(viewH) || est);
  let from = 0;
  while (from < count && tops[from] + hAt(from) < viewTop) from += 1;
  let to = from;
  while (to < count && tops[to] < viewBot) to += 1;
  from = Math.max(0, from - overscan);
  to = Math.min(count, Math.max(from, to) + overscan);
  const padTop = tops[from] || 0;
  const last = Math.max(from, to - 1);
  const endY = to > from ? tops[last] + hAt(last) : padTop;
  return { from, to, padTop, padBottom: Math.max(0, total - endY), total };
}
