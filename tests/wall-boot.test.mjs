/**
 * Boot gate: the inline app script must evaluate to the end and the wall must
 * paint a first page.
 *
 * Why this exists: a top-level `window.setInterval(nowMarkerTick, NOW_MARKER_MS)`
 * placed *before* `const NOW_MARKER_MS` threw a TDZ ReferenceError at script
 * evaluation. Every source scan still passed (function declarations are hoisted,
 * so `typeof dayHeadMarkup === 'function'` stayed true) and `node --check` was
 * happy — the page just never booted, live, with the wall blank. Only a browser
 * probe caught it. This test is that probe, in jsdom: the whole inline script
 * runs with a stubbed fetch/EventSource, and a throw (or a blank wall) fails.
 *
 * Run via scripts/check-frontend.sh (listed in the gates comment).
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

/**
 * The fixture day must be **today in the wall display zone**. The 现在 line and the
 * day-head aggregate only render on the current capture day, so a pinned date
 * (`2026-10-15`) made this gate pass until the calendar moved past it and then fail
 * forever — a time bomb, not a probe.
 */
const TZ = 'Asia/Shanghai';
const TODAY_KEY = new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
}).format(new Date());
const TODAY_WALL = TODAY_KEY.replace(/-/g, '/');

/** A page of cards that the stubbed fetch serves, plus a day-aggregate payload. */
const CLIPS = {
  items: [
    { id: '11111111-1111-4111-8111-111111111111', timestamp: Date.now() / 1000 - 60, type: 'text', text: 'hello', timeLocal: `${TODAY_WALL} 11:20:00` },
    { id: '22222222-2222-4222-8222-222222222222', timestamp: Date.now() / 1000 - 120, type: 'image', timeLocal: `${TODAY_WALL} 11:10:00` },
  ],
  nextCursor: null,
  count: 2,
};
const DAYS = {
  tz: 'Asia/Shanghai',
  binMinutes: 5,
  bins: 288,
  count: 1,
  days: [{
    day: TODAY_KEY, total: 2, timed: 2, night: 0, firstMin: 670, lastMin: 685,
    maxGapMin: 5, gapFromMin: 670, gapToMin: 675, byType: { text: 1, image: 1 },
    bins: Array.from({ length: 288 }, (_, i) => (i === 134 || i === 137 ? 1 : 0)),
  }],
};

function boot() {
  const errors = [];
  const dom = new JSDOM(html, {
    url: 'http://127.0.0.1:8080/',
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    resources: undefined,   // never fetch CDN scripts: the inline script must stand alone
    beforeParse(window) {
      window.addEventListener('error', (ev) => errors.push(String(ev.error && ev.error.stack || ev.message)));
      window.addEventListener('unhandledrejection', (ev) => errors.push('unhandled rejection: ' + String(ev.reason)));
      // Server-injected wall clock (sendHTMLResponse) — same shape the live page gets.
      window.TextDecoder = TextDecoder;
      window.TextEncoder = TextEncoder;
      window.__CLIP_TZ = TZ;
      window.__CLIP_TZ_OFFSET_MIN = 480;
      window.fetch = async (url) => {
        const u = String(url);
        const body = u.includes('/api/clips/days') ? DAYS : (u.includes('/api/clips') ? CLIPS : {});
        return { ok: true, status: 200, arrayBuffer: async () => Buffer.from(JSON.stringify(body)), json: async () => body, text: async () => JSON.stringify(body) };
      };
      class FakeSource {
        constructor() { this.readyState = 1; }
        addEventListener() {}
        close() {}
      }
      window.EventSource = FakeSource;
      window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
      window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } };
      window.BroadcastChannel = class { postMessage() {} close() {} addEventListener() {} };
      window.requestIdleCallback = (fn) => window.setTimeout(() => fn({ didTimeout: false, timeRemaining: () => 5 }), 0);
    },
  });
  return { dom, errors };
}

const settle = async (dom, ms = 300) => new Promise((resolve) => setTimeout(resolve, ms));

function fakeScroll(window, y) {
  Object.defineProperty(window, 'scrollY', { configurable: true, writable: true, value: y });
  window.scrollTo = (options, top) => {
    window.scrollY = typeof options === 'object' ? options.top : top;
    window.document.documentElement.scrollTop = window.scrollY;
  };
}

function wheel(window, target, dy, dx = 0) {
  const event = new window.WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: dy, deltaX: dx });
  target.dispatchEvent(event);
  return event.defaultPrevented;
}

function touch(window, target, type, x, y) {
  const event = new window.Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, 'touches', { value: [{ clientX: x, clientY: y }] });
  target.dispatchEvent(event);
  return event.defaultPrevented;
}

test('note list edits recolor the same row while clipboard cards remain unchanged', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom);
  const w = dom.window;
  const card = w.document.querySelector(`[data-id="${CLIPS.items[0].id}"]`);
  assert.ok(card);
  assert.equal(card.dataset.editLevel, undefined);
  assert.equal(card.querySelector('.note-edit-count'), null);

  const note = { id: 'note', type: 'note', textContent: '# A note\n\nwriting', editCount: 1 };
  const row = w.document.createElement('button');
  row.className = 'note-row';
  w.fillNoteRow(row, note, '');
  const title = row.querySelector('.nt');
  const pin = row.querySelector('.note-pin');
  assert.equal(row.dataset.editLevel, '1');
  w.fillNoteRow(row, { ...note, editCount: 6 }, '');
  assert.equal(row.dataset.editLevel, '4');
  assert.equal(row.querySelector('.note-edit-count').textContent, '编辑 6 次');
  assert.strictEqual(row.querySelector('.nt'), title);
  assert.strictEqual(row.querySelector('.note-pin'), pin);
  w.fillNoteRow(row, { ...note, editCount: 0 }, '');
  assert.equal(row.dataset.editLevel, '0');
  assert.equal(row.querySelector('.note-edit-count'), null);
  assert.deepEqual(errors, []);
});

test('search hits inside note tags remain highlighted and clickable at the deepest edit level', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 50);
  const w = dom.window;
  const row = w.document.createElement('button');
  row.className = 'note-row';
  w.fillNoteRow(row, { id: 'tagged', type: 'note', textContent: '# #gateway Design\n\ngateway notes', editCount: 654 }, 'gateway');
  assert.equal(row.dataset.editLevel, '15');
  assert.equal(row.querySelector('.notes-tag mark.search-hit').textContent, 'gateway');
  assert.ok(row.querySelector('.nx mark.search-hit'));
  row.querySelector('.notes-tag mark.search-hit').click();
  assert.equal(w.eval('notesState.tagFilter'), 'gateway', 'the highlight keeps the existing tag-filter action');
  assert.deepEqual(errors, []);
});

test('note color scale previews all 16 steps without changing a note or replacing swatches', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 50);
  const w = dom.window;
  w.eval('notesState.items = [{ id: "selected", editCount: 200 }]; notesState.id = "selected"; paintNotesWarmthScale();');
  const track = w.document.getElementById('notesWarmthTrack');
  const chip = w.document.getElementById('notesWarmthChip');
  const readout = w.document.getElementById('notesWarmthReadout');
  const swatches = [...track.children];
  assert.equal(swatches.length, 16);
  assert.equal(track.querySelector('.is-current').dataset.editLevel, '13');
  assert.equal(track.getAttribute('aria-valuenow'), '14');
  track.focus();
  track.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'End', bubbles: true }));
  assert.equal(chip.dataset.editLevel, '15');
  assert.equal(chip.style.getPropertyValue('--edit-ratio'), '0.9375');
  assert.match(readout.textContent, /第 16\/16 档 · 雾紫 · ≥450 次编辑/);
  assert.equal(track.getAttribute('aria-valuenow'), '16');
  track.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
  assert.equal(chip.dataset.editLevel, '0');
  track.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
  assert.equal(chip.dataset.editLevel, '1');
  track.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  assert.equal(track.getAttribute('aria-valuenow'), '14');
  assert.equal(w.eval('notesState.items[0].editCount'), 200, 'preview never mutates note history');
  assert.deepEqual([...track.children], swatches, 'scale keeps stable DOM identities');
  w.showNoteWarmthPreview(999);
  assert.equal(chip.dataset.editLevel, '15');
  track.dispatchEvent(new w.Event('pointerleave'));
  assert.equal(track.getAttribute('aria-valuenow'), '14');
  assert.deepEqual(errors, []);
});

test('nested modals hold one fixed wall position until the last owner closes', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 50);
  const w = dom.window;
  fakeScroll(w, 900);
  w.openEvalSheet(CLIPS.items[0]);
  assert.equal(w.document.body.style.position, 'fixed');
  assert.equal(w.document.body.style.top, '-900px');
  // A real browser resets root scroll when the body becomes fixed.
  w.scrollY = 0;
  w.openLightbox('/test.png', CLIPS.items[1]);
  w.closeLightbox();
  w.closeLightbox(); // redundant Escape handlers must not release another modal
  assert.equal(w.document.body.dataset.scrollLock, '1');
  assert.equal(w.document.body.style.top, '-900px');
  w.closeEvalSheet();
  assert.equal(w.document.body.style.position, '');
  assert.equal(w.document.body.dataset.scrollLock, '');
  assert.equal(w.scrollY, 900);
  assert.equal(w.document.documentElement.classList.contains('page-scroll-locked'), false);
  assert.deepEqual(errors, []);
});

test('modal gestures scroll inside content and stop at either boundary, including touch', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 50);
  const w = dom.window;
  fakeScroll(w, 450);
  w.openEvalSheet(CLIPS.items[0]);
  const box = w.document.createElement('div');
  box.style.overflowY = 'auto';
  box.style.overflowX = 'auto';
  Object.defineProperties(box, {
    clientHeight: { value: 200 }, scrollHeight: { value: 600 },
    clientWidth: { value: 200 }, scrollWidth: { value: 400 },
  });
  w.document.querySelector('#evalSheet .eval-sheet-card').append(box);
  box.scrollTop = 100;
  assert.equal(wheel(w, box, 50), false, 'inner content remains scrollable');
  assert.equal(wheel(w, box, -50), false);
  box.scrollTop = 0;
  assert.equal(wheel(w, box, -50), true, 'top edge cannot pull the wall');
  box.scrollTop = 400;
  assert.equal(wheel(w, box, 50), true, 'bottom edge cannot push the wall');
  box.scrollLeft = 50;
  assert.equal(wheel(w, box, 0, 20), false, 'horizontal content remains scrollable');
  box.scrollLeft = 200;
  assert.equal(wheel(w, box, 0, 20), true);
  assert.equal(wheel(w, w.document.getElementById('evalSheetScrim'), 50), true);
  assert.equal(wheel(w, w.document.querySelector('main'), 50), true);
  box.scrollTop = 100;
  touch(w, box, 'touchstart', 100, 200);
  assert.equal(touch(w, box, 'touchmove', 100, 150), false);
  box.scrollTop = 400;
  assert.equal(touch(w, box, 'touchmove', 100, 100), true);
  w.closeEvalSheet();
  assert.equal(wheel(w, w.document.querySelector('main'), 50), false);
  assert.deepEqual(errors, []);
});

test('reader, repeat history, and link popovers all acquire and release the wall lock', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 50);
  const w = dom.window;
  fakeScroll(w, 700);
  w.openArchiveReader(CLIPS.items[0]);
  assert.equal(w.document.body.dataset.scrollLock, '1');
  w.closeArchiveReader();
  assert.equal(w.scrollY, 700);
  const anchor = w.document.getElementById('notesOpenBtn');
  await w.openEventToast(CLIPS.items[0].id, {}, anchor);
  assert.equal(w.document.body.dataset.scrollLock, '1');
  w.closeEventToast();
  assert.equal(w.document.body.dataset.scrollLock, '');
  await w.openLinkToast(CLIPS.items[0], anchor);
  assert.equal(w.document.body.dataset.scrollLock, '1');
  w.closeLinkToast();
  assert.equal(w.document.body.dataset.scrollLock, '');
  assert.deepEqual(errors, []);
});

test('wall-boot gate is registered in check-frontend.sh', () => {
  const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');
  assert.match(check, /wall-boot\.test\.mjs/);
});

test('the inline app script evaluates to the end (no TDZ / early throw)', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom);
  // A late-bound global proves evaluation ran past every earlier top-level block:
  // the boot call is the last statement of the inline script.
  const w = dom.window;
  assert.deepEqual(errors, [], `inline script threw: ${errors.join(' | ')}`);
  assert.equal(typeof w.ClipViewDayRhythm, 'object');
  assert.equal(typeof w.wallNowMinute, 'function');
  // The marker tick must actually be armed (the TDZ bug killed it silently).
  assert.equal(typeof w.nowMarkerTick, 'function');
});

test('the wall paints its first page from the stubbed API', { skip: skipJsdom }, async (t) => {
  const { dom, errors } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 400);
  const w = dom.window;
  const feed = w.document.getElementById('grid');
  assert.ok(feed, 'feed container missing');
  assert.deepEqual(errors, [], `inline script threw: ${errors.join(' | ')}`);
  const cards = feed.querySelectorAll('.m3-card');
  assert.equal(cards.length, 2, `expected the first page to paint, got ${cards.length} cards`);
  const head = feed.querySelector('.day-head');
  assert.ok(head, 'day head missing');
  assert.match(head.textContent, /共 2 条/, 'the head must print the store aggregate');
  assert.equal(head.querySelectorAll('.rhythm-bar').length, 288);
  assert.equal(w.document.querySelectorAll('.rhythm-nightzone').length, 2, 'night band is part of the strip');
});

test('the 现在 line is armed and moves on the compositor', { skip: skipJsdom }, async (t) => {
  const { dom } = boot();
  t.after(() => dom.window.close());
  await settle(dom, 400);
  const w = dom.window;
  const marker = w.document.querySelector('.rhythm-now');
  assert.ok(marker, 'today\'s head must carry the 现在 line');
  const before = marker.style.transform;
  // Rewind/fast-forward the wall clock and move it: transform only, no rebuild.
  w.wallNowMinute = () => 1200;
  w.nowMarkerTick();
  assert.notEqual(marker.style.transform, before);
  assert.match(marker.style.transform, /^translateX\(\d+(\.\d+)?px\)$/);
  assert.match(marker.title, /^现在 20:00$/);
  assert.equal(marker.parentElement.querySelectorAll('.rhythm-now').length, 1, 'no duplicate markers');
});
