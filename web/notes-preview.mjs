/**
 * Notes preview renderer: React 18 reconciler over compiled markdown blocks.
 * Identity is token hash, not source line — insert-above does not remount.
 * Line attrs live on the wrapper so scroll-sync can update without recompile.
 */
import { createElement, memo, useLayoutEffect } from 'react';
import { createRoot } from 'react-dom/client';

const Block = memo(function NotesMdBlock({ html, lineFrom, lineTo }) {
  return createElement('div', {
    className: 'notes-md-block',
    'data-source-line': String(lineFrom),
    'data-source-end-line': String(lineTo),
    dangerouslySetInnerHTML: { __html: html },
  });
});

function Preview({ blocks, scrollEl, keepTop, stickBottom, onPainted }) {
  useLayoutEffect(() => {
    if (scrollEl) {
      if (stickBottom) scrollEl.scrollTop = scrollEl.scrollHeight;
      else if (keepTop != null) scrollEl.scrollTop = keepTop;
    }
    if (typeof onPainted === 'function') onPainted();
  });
  return (blocks || []).map((b) => createElement(Block, {
    key: b.key,
    html: b.html,
    lineFrom: b.lineFrom,
    lineTo: b.lineTo,
  }));
}

/**
 * @param {HTMLElement} el
 * @returns {{ render: Function, unmount: Function }}
 */
export function mountNotesPreview(el) {
  const root = createRoot(el);
  return {
    render(blocks, opts = {}) {
      root.render(createElement(Preview, {
        blocks: blocks || [],
        scrollEl: opts.scrollEl || (el && el.parentElement),
        keepTop: opts.keepTop,
        stickBottom: !!opts.stickBottom,
        onPainted: opts.onPainted,
      }));
    },
    unmount() {
      root.unmount();
    },
  };
}
