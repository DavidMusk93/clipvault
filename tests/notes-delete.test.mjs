/**
 * Note delete: Apple list semantics (swipe reveals one trailing action) plus the
 * guarantee that a deleted note is recoverable.
 *
 * The product rule this pins: delete is a **soft delete to the 30-day recycle
 * bin**, offered with an undo, and the bin must actually show notes — a delete
 * nobody can reach afterwards is the "记忆不可丢" failure, not a feature.
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

function fnSource(name) {
  const start = html.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} missing in web/index.html`);
  if (html.slice(start - 6, start) === 'async ') {
    // async helpers are not needed here
  }
  const open = html.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth += 1;
    else if (html[i] === '}') {
      depth -= 1;
      if (depth === 0) return html.slice(start, i + 1);
    }
  }
  throw new Error(`${name} unbalanced`);
}

const swipeDecision = new Function(
  'const NOTE_SWIPE_WIDTH = 84; const NOTE_SWIPE_OPEN_AT = 30; const NOTE_SWIPE_DELETE_AT = 130;\n'
  + fnSource('noteSwipeDecision') + '\nreturn noteSwipeDecision;',
)();

test('swipe travel decides delete / open / close on Apple thresholds', () => {
  assert.equal(swipeDecision(0), 'close');
  assert.equal(swipeDecision(-29), 'close');
  assert.equal(swipeDecision(-30), 'open');
  assert.equal(swipeDecision(-84), 'open');
  assert.equal(swipeDecision(-129), 'open');
  assert.equal(swipeDecision(-130), 'delete');
  assert.equal(swipeDecision(-220), 'delete');
  assert.equal(swipeDecision(-10), 'close', 'dragging right from the open state closes');
});

test('the trailing action is drag-only: hover must never advertise deletion', () => {
  assert.match(html, /\.note-row-actions \{/);
  assert.match(html, /\.note-del \{/);
  assert.match(html, /\.note-row\[data-swiped="1"\] \{ --note-reveal: 84px; \}/);
  assert.match(html, /transform: translateX\(calc\(100% - var\(--note-reveal, 0px\)\)\)/);
  assert.match(html, /touch-action: pan-y/);
  assert.match(html, /prefers-reduced-motion: reduce\) \{\s*\.note-row-clip, \.note-row-actions \{ transition: none; \}/);
  assert.match(html, /data-note-del/);
  assert.doesNotMatch(html, /\.note-row:hover \{ --note-reveal/, 'hover reveal turns the list into a delete surface');
  assert.doesNotMatch(html, /:focus-within:not\(:focus\)/, 'focus must not pop the action either');
  const gestures = fnSource('bindNoteRowGestures');
  assert.doesNotMatch(gestures, /pointerType === 'mouse'/, 'a mouse drag must reveal the same action as a finger');
  assert.match(gestures, /setPointerCapture/);
  const swiped = fnSource('setNoteRowSwiped');
  assert.match(swiped, /tabindex/, 'the action only joins the tab order while it is revealed');
  assert.match(html, /key === 'Escape' && btn\.dataset\.swiped === '1'/);
});

test('the recycle bin keeps notes so a delete is recoverable', () => {
  const wallParams = fnSource('applyWallQueryParams');
  assert.match(wallParams, /else if \(currentView !== 'trash'\) params\.set\('exclude', 'note'\)/);
  const dayIndex = html.slice(html.indexOf('function fetchDayIndex'));
  assert.match(dayIndex.slice(0, 900), /currentView !== 'trash'/);
});

function boot() {
  const calls = [];
  const notes = [
    { id: 'note-1', type: 'note', editCount: 3, timestamp: Date.now() / 1000, textContent: '# 甲\n\n第一帧' },
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
        const method = (opts.method || 'GET').toUpperCase();
        calls.push({ url: u, method });
        let body = {};
        if (u.includes('/api/clips/restore')) body = { status: 'restored' };
        else if (method === 'DELETE') body = { status: 'deleted', soft: true };
        else if (u.includes('/api/clips?id=')) body = { items: notes.filter((n) => u.includes(n.id)) };
        else if (u.includes('/api/clips')) body = { items: notes, nextCursor: null };
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
    },
  });
  return { dom, calls, notes };
}

const settle = (ms = 200) => new Promise((r) => setTimeout(r, ms));

async function openPanel(dom) {
  const w = dom.window;
  await w.openNotesPanel();
  for (let i = 0; i < 40 && !w.document.querySelector('.note-row'); i++) await settle(50);
  return w;
}

test('deleting a note removes the row, offers undo, and undo restores it', { skip: skipJsdom }, async (t) => {
  const { dom, calls } = boot();
  t.after(() => dom.window.close());
  const w = await openPanel(dom);
  const rows = [...w.document.querySelectorAll('.note-row')];
  assert.equal(rows.length, 2);
  const first = rows[0];
  const id = first.dataset.noteId;
  assert.ok(first.querySelector('.note-del'), 'each row carries the trailing action');
  first.querySelector('.note-del').dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await settle(300);
  assert.equal(w.document.querySelectorAll('.note-row').length, 1, 'the deleted row leaves the list');
  assert.ok(calls.some((c) => c.method === 'DELETE' && c.url.includes(id)), 'soft delete hits the API');
  const snack = w.document.getElementById('snackbar');
  assert.ok(snack.classList.contains('show'));
  assert.match(w.document.getElementById('snackbarText').textContent, /已删除「甲」/);
  const action = w.document.getElementById('snackbarAction');
  assert.equal(action.hidden, false);
  assert.equal(action.textContent, '撤销');
  action.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await settle(400);
  assert.ok(calls.some((c) => c.method === 'POST' && c.url.includes('/api/clips/restore')), 'undo restores');
  assert.equal(w.document.querySelectorAll('.note-row').length, 2, 'the row comes back');
});

test('deleting the open note opens the next one instead of a stale paper', { skip: skipJsdom }, async (t) => {
  const { dom } = boot();
  t.after(() => dom.window.close());
  const w = await openPanel(dom);
  await w.openNoteInPanel('note-1');
  await settle(300);
  assert.equal(w.eval('notesState.id'), 'note-1');
  await w.deleteNote('note-1');
  await settle(300);
  assert.equal(w.eval('notesState.id'), 'note-2', 'selection moves on');
  assert.match(w.document.getElementById('notesTitle').value, /乙/);
});

test('keyboard Delete on a focused row deletes it', { skip: skipJsdom }, async (t) => {
  const { dom, calls } = boot();
  t.after(() => dom.window.close());
  const w = await openPanel(dom);
  const row = w.document.querySelector('.note-row');
  const id = row.dataset.noteId;
  row.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Delete', bubbles: true }));
  await settle(300);
  assert.ok(calls.some((c) => c.method === 'DELETE' && c.url.includes(id)));
  assert.equal(w.document.querySelectorAll('.note-row').length, 1);
});

test('a peer delete clears the note row and closes the editor without saving', { skip: skipJsdom }, async (t) => {
  const { dom, calls } = boot();
  t.after(() => dom.window.close());
  const w = await openPanel(dom);
  await w.openNoteInPanel('note-1');
  await settle(300);
  const before = calls.length;
  w.applyRemoteClipRemoval({ id: 'note-1', type: 'clip_deleted' });
  await settle(300);
  assert.equal(w.document.querySelectorAll('.note-row').length, 1);
  assert.ok(!w.eval('notesState.id'), 'editor dropped the deleted note');
  assert.ok(!calls.slice(before).some((c) => c.method === 'POST'), 'a peer delete must not resurrect by saving');
});
