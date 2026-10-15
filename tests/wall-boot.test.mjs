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

/** A page of cards that the stubbed fetch serves, plus a day-aggregate payload. */
const CLIPS = {
  items: [
    { id: '11111111-1111-4111-8111-111111111111', timestamp: Date.now() / 1000 - 60, type: 'text', text: 'hello', timeLocal: '2026/10/15 11:20:00' },
    { id: '22222222-2222-4222-8222-222222222222', timestamp: Date.now() / 1000 - 120, type: 'image', timeLocal: '2026/10/15 11:10:00' },
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
    day: '2026-10-15', total: 2, timed: 2, night: 0, firstMin: 670, lastMin: 685,
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
      window.__CLIP_TZ = 'Asia/Shanghai';
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

test('wall-boot gate is registered in check-frontend.sh', () => {
  const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');
  assert.match(check, /wall-boot\.test\.mjs/);
});

test('the inline app script evaluates to the end (no TDZ / early throw)', { skip: skipJsdom }, async () => {
  const { dom, errors } = boot();
  await settle(dom);
  // A late-bound global proves evaluation ran past every earlier top-level block:
  // the boot call is the last statement of the inline script.
  const w = dom.window;
  assert.deepEqual(errors, [], `inline script threw: ${errors.join(' | ')}`);
  assert.equal(typeof w.ClipViewDayRhythm, 'object');
  assert.equal(typeof w.wallNowMinute, 'function');
  // The marker tick must actually be armed (the TDZ bug killed it silently).
  assert.equal(typeof w.nowMarkerTick, 'function');
  dom.window.close();
});

test('the wall paints its first page from the stubbed API', { skip: skipJsdom }, async () => {
  const { dom, errors } = boot();
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
  dom.window.close();
});

test('the 现在 line is armed and moves on the compositor', { skip: skipJsdom }, async () => {
  const { dom } = boot();
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
  dom.window.close();
});
