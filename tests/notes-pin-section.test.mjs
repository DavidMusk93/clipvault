/**
 * Note pins must be readable at a glance.
 *
 * The product rule this pins: **pin is a state channel, not a hue.** The notes
 * list already spends hue on edit volume (16 papers / 4 families), amber on
 * tags, cream on search hits and accent on selection, so a tinted pin glyph
 * reads as one more coloured patch on an already coloured row — which is why
 * pinning was invisible. The state now rides on shape and ink weight (solid ink
 * chip + filled glyph) and the pinned block gets a labelled hairline.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';
import { TextDecoder, TextEncoder } from 'node:util';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');

let JSDOM = null;
let skipJsdom = false;
try {
  ({ JSDOM } = await import('jsdom'));
} catch {
  skipJsdom = 'jsdom not installed — run `npm ci`';
}

test('the pin spends shape and ink, never a hue the list already uses', () => {
  const pinned = html.match(/\.note-row\.is-pinned \.note-pin \{[^}]*\}/);
  assert.ok(pinned, 'pinned pin rule missing');
  assert.match(pinned[0], /color: #fff/);
  assert.match(pinned[0], /background: var\(--ink\)/);
  assert.doesNotMatch(pinned[0], /--accent/, 'accent is the selection channel and the blue family spine');
  assert.match(
    html,
    /\.note-row\.is-pinned \.note-pin \.material-symbols-outlined \{\s*font-variation-settings: 'FILL' 1/,
    'a filled glyph separates pinned from free without colour',
  );
  assert.doesNotMatch(html, /is-pinned \.note-pin \{[^}]*--accent/, 'a tinted glyph is what made pinning invisible');
});

test('the pinned block is separated by a labelled hairline, not by a tinted row', () => {
  assert.match(html, /\.notes-pin-head \{/);
  assert.match(html, /\.notes-pin-head::after \{[^}]*height: 0\.5px/);
  const head = html.slice(html.indexOf('const pinnedCount = rows.filter(noteIsPinned)'), html.indexOf('let prev = null;'));
  assert.match(head, /pinHead\.textContent = '置顶'/);
  assert.match(head, /rows\.slice\(0, pinnedCount\)\.every\(noteIsPinned\)/, 'no header when search interleaves pinned rows');
  // Paper colour answers edit volume only; pinning must not repaint the paper.
  assert.doesNotMatch(html, /\.note-row\.is-pinned \{[^}]*--edit-paper/, 'pin must not touch the volume channel');
});

function boot() {
  const notes = [
    { id: 'note-1', type: 'note', pinned: true, pinnedAt: 1700000000, editCount: 3, timestamp: Date.now() / 1000, textContent: '# 甲\n\n第一帧' },
    { id: 'note-2', type: 'note', editCount: 0, timestamp: Date.now() / 1000 - 60, textContent: '# 乙\n\n第二帧' },
  ];
  const dom = new JSDOM(html, {
    url: 'http://127.0.0.1:8080/',
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    resources: undefined,
    beforeParse(window) {
      window.TextDecoder = TextDecoder;
      window.CSS = window.CSS || { supports: () => false, escape: (v) => String(v).replace(/["\\]/g, '\\$&') };
      window.TextEncoder = TextEncoder;
      window.__CLIP_TZ = 'Asia/Shanghai';
      window.__CLIP_TZ_OFFSET_MIN = 480;
      window.fetch = async (url, opts = {}) => {
        const u = String(url);
        const body = u.includes('/api/clips/pin')
          ? { ok: true, item: { id: 'note-1', pinned: false, pinnedAt: null } }
          : { items: notes, nextCursor: null };
        const text = JSON.stringify(body);
        return { ok: true, status: 200, json: async () => body, text: async () => text, arrayBuffer: async () => Buffer.from(text) };
      };
      window.ClipNotesEditor = {
        mount: async (host, opts = {}) => ({
          setMarkdown() {},
          getMarkdown: () => opts.markdown || '',
          getMode: () => opts.mode || 'preview',
          focus() {},
          setMode() {},
          scrollToLine() {},
          clearFind() {},
          closeFind() {},
          find() {},
          focusMatch() {},
          destroy() {},
        }),
      };
      class FakeSource { constructor() { this.readyState = 1; } addEventListener() {} close() {} }
      window.EventSource = FakeSource;
      window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
      window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } };
      window.BroadcastChannel = class { postMessage() {} close() {} addEventListener() {} };
      window.requestIdleCallback = (fn) => window.setTimeout(() => fn({ didTimeout: false, timeRemaining: () => 5 }), 0);
      window.confirm = () => true;
    },
  });
  return dom;
}

const settle = (ms = 200) => new Promise((r) => setTimeout(r, ms));

test('pinned notes open under a 置顶 header, and the header follows the state', { skip: skipJsdom }, async (t) => {
  const dom = boot();
  t.after(() => dom.window.close());
  const w = dom.window;
  await w.openNotesPanel();
  for (let i = 0; i < 40 && !w.document.querySelector('.note-row'); i++) await settle(50);

  const list = w.document.getElementById('notesList');
  const rows = [...list.querySelectorAll('.note-row')];
  assert.equal(rows.length, 2);
  assert.ok(list.firstElementChild.classList.contains('notes-pin-head'), 'the 置顶 header heads the list');
  assert.equal(list.firstElementChild.textContent, '置顶');
  assert.equal(rows[0].dataset.noteId, 'note-1');
  assert.equal(rows[0].querySelector('.note-pin').getAttribute('aria-pressed'), 'true');
  assert.equal(rows[1].querySelector('.note-pin').getAttribute('aria-pressed'), 'false');

  rows[0].querySelector('.note-pin').dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await settle(300);
  const after = [...w.document.getElementById('notesList').querySelectorAll('.note-row')];
  assert.equal(w.document.querySelector('.notes-pin-head'), null, 'no pinned block, no header');
  assert.equal(after[0].querySelector('.note-pin').getAttribute('aria-pressed'), 'false');
});
