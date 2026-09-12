/**
 * Notes preview renderer: React 18 reconciler over compiled markdown blocks.
 * Identity is token hash, not source line — insert-above does not remount.
 * Line attrs live on the wrapper so scroll-sync can update without recompile.
 * Long notes window the DOM: 25k blocks must not mount at once (blank paper).
 */
import { createElement, memo, useLayoutEffect, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { previewWindow } from './notes-preview-window.mjs';

export { previewWindow, PREVIEW_EST_H, PREVIEW_OVERSCAN, PREVIEW_WINDOW_MIN } from './notes-preview-window.mjs';

const Block = memo(function NotesMdBlock({ html, lineFrom, lineTo }) {
  return createElement('div', {
    className: 'notes-md-block',
    'data-source-line': String(lineFrom),
    'data-source-end-line': String(lineTo),
    dangerouslySetInnerHTML: { __html: html },
  });
});

function Preview({ blocks, scrollEl, keepTop, stickBottom, onPainted }) {
  const list = blocks || [];
  const n = list.length;
  const heightsRef = useRef([]);
  const boxRef = useRef(null);
  const [win, setWin] = useState(() => previewWindow(0, 900, n, []));

  const recompute = () => {
    const el = scrollEl;
    const next = previewWindow(
      el ? el.scrollTop : 0,
      el ? el.clientHeight : 900,
      n,
      heightsRef.current,
    );
    setWin((prev) => (
      prev.from === next.from
      && prev.to === next.to
      && prev.padTop === next.padTop
      && prev.padBottom === next.padBottom
        ? prev
        : next
    ));
  };

  useEffect(() => {
    heightsRef.current = [];
    recompute();
  }, [list, n]);

  useEffect(() => {
    if (!scrollEl) return undefined;
    const onScroll = () => recompute();
    scrollEl.addEventListener('scroll', onScroll, { passive: true });
    return () => scrollEl.removeEventListener('scroll', onScroll);
  }, [scrollEl, n]);

  useLayoutEffect(() => {
    const box = boxRef.current;
    if (box) {
      const nodes = box.querySelectorAll(':scope > .notes-md-block');
      let i = 0;
      for (const node of nodes) {
        const idx = win.from + i;
        const host = node.firstElementChild || node;
        const h = host.getBoundingClientRect().height;
        if (Number.isFinite(h) && h > 0) heightsRef.current[idx] = h;
        i += 1;
      }
    }
    if (typeof onPainted === 'function') onPainted();
  }, [win.from, win.to, list]);

  useLayoutEffect(() => {
    if (!scrollEl) return;
    if (stickBottom) scrollEl.scrollTop = scrollEl.scrollHeight;
    else if (keepTop != null) scrollEl.scrollTop = keepTop;
  }, [list]);

  const slice = list.slice(win.from, win.to);
  const kids = [];
  if (win.padTop > 0) {
    kids.push(createElement('div', {
      key: 'pad-top',
      className: 'notes-md-pad',
      'aria-hidden': 'true',
      style: { height: win.padTop },
    }));
  }
  for (const b of slice) {
    kids.push(createElement(Block, {
      key: b.key,
      html: b.html,
      lineFrom: b.lineFrom,
      lineTo: b.lineTo,
    }));
  }
  if (win.padBottom > 0) {
    kids.push(createElement('div', {
      key: 'pad-bot',
      className: 'notes-md-pad',
      'aria-hidden': 'true',
      style: { height: win.padBottom },
    }));
  }
  return createElement('div', { className: 'notes-preview-window', ref: boxRef }, kids);
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
