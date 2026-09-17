/**
 * Front-end interaction tracking contract (web/assets/ui-track.js).
 *
 * The delegated listener must turn clicks / changes / shortcuts into a bounded
 * `ui_interact` payload — and must never carry element text or input values.
 *
 * Run: node --test tests/ui-track.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers/src.mjs';

const trackSrc = readFileSync(join(root, 'web/assets/ui-track.js'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const sessionsHtml = readFileSync(join(root, 'trae_hooks/web/sessions.html'), 'utf8');
const metricsJs = readFileSync(join(root, 'web/assets/notes-metrics.js'), 'utf8');
const panelJs = readFileSync(join(root, 'web/assets/metrics-panel.js'), 'utf8');
const swift = readFileSync(join(root, 'Sources/ClipVault/Metrics/UiMetrics.swift'), 'utf8');

let JSDOM = null;
try {
  ({ JSDOM } = await import('jsdom'));
} catch {
  // jsdom is a dev-only dep; skip the DOM half cleanly when absent.
}

function boot(htmlBody) {
  const dom = new JSDOM(`<!doctype html><html><body>${htmlBody}</body></html>`, {
    runScripts: 'outside-only',
  });
  dom.window.eval(trackSrc);
  const seen = [];
  dom.window.ClipUiTrack.install((name, extra) => seen.push({ name, payload: extra.payload }), { zone: 'wall' });
  return { dom, win: dom.window, doc: dom.window.document, seen };
}

const click = (win, el) => el.dispatchEvent(new win.MouseEvent('click', { bubbles: true, button: 0 }));
const change = (win, el) => el.dispatchEvent(new win.Event('change', { bubbles: true }));
// jsdom realm objects have a foreign prototype; compare as plain JSON.
const plain = (o) => JSON.parse(JSON.stringify(o));

test('ui-track source never reads element text or input values', () => {
  assert.doesNotMatch(trackSrc, /textContent|innerText|\.value\b/);
  assert.doesNotMatch(trackSrc, /getMarkdown|localStorage/);
  assert.match(trackSrc, /ui_interact/);
  assert.match(trackSrc, /data-ui-zone/);
  assert.match(trackSrc, /ClipUiTrack/);
});

test('pages load ui-track and wire it to their own emitter', () => {
  assert.match(html, /assets\/ui-track\.js/);
  assert.match(html, /ClipUiTrack\?\.install\(nm, \{ zone: 'wall' \}\)/);
  assert.match(html, /data-ui-zone="wall"/);
  assert.match(html, /data-ui-zone="notes"/);
  assert.match(html, /data-ui-zone="sessions"/);
  assert.match(html, /data-ui-zone="topbar"/);
  assert.match(html, /data-ui-zone="debug"/);
  assert.match(sessionsHtml, /assets\/ui-track\.js/);
  assert.match(sessionsHtml, /ClipUiTrack\?\.install\(emit, \{ zone: "sessions" \}\)/);
});

test('allowlists accept zone/action/target/via on both sides', () => {
  assert.match(metricsJs, /'zone', 'action', 'target', 'via'/);
  assert.match(sessionsHtml, /zone\|action\|target\|via/);
  assert.match(swift, /"zone", "action", "target", "via"/);
  assert.match(panelJs, /ui_interact/);
  assert.match(html, /ui_interact: \{ label: '交互'/);
});

test('click derives action + target from action attributes', () => {
  if (!JSDOM) return;
  const { win, doc, seen } = boot(`
    <div data-ui-zone="wall">
      <button class="icon-btn" data-pin="abc">x</button>
      <button class="icon-btn" data-del="abc">y</button>
    </div>`);
  click(win, doc.querySelector('[data-pin]'));
  click(win, doc.querySelector('[data-del]'));
  assert.deepEqual(seen.map((e) => e.name), ['ui_interact', 'ui_interact']);
  assert.deepEqual(plain(seen[0].payload), { zone: 'wall', action: 'pin', target: 'data-pin', via: 'click' });
  assert.deepEqual(plain(seen[1].payload), { zone: 'wall', action: 'delete', target: 'data-del', via: 'click' });
});

test('zone comes from the nearest data-ui-zone, id/class fall back as target', () => {
  if (!JSDOM) return;
  const { win, doc, seen } = boot(`
    <div data-ui-zone="notes">
      <button id="notesNew">新一篇</button>
      <button class="fmt-btn" data-mode="split">分栏</button>
    </div>`);
  click(win, doc.getElementById('notesNew'));
  click(win, doc.querySelector('[data-mode]'));
  assert.deepEqual(plain(seen[0].payload), { zone: 'notes', action: 'click', target: 'notesNew', via: 'click' });
  assert.deepEqual(plain(seen[1].payload), { zone: 'notes', action: 'mode', target: 'data-mode', via: 'click' });
});

test('change reports input kind but not its value', () => {
  if (!JSDOM) return;
  const { win, doc, seen } = boot(`
    <div data-ui-zone="chips">
      <input id="wallSearch" type="search" value="secret query" />
    </div>`);
  change(win, doc.getElementById('wallSearch'));
  assert.equal(seen.length, 1);
  assert.deepEqual(plain(seen[0].payload), { zone: 'chips', action: 'input', target: 'wallSearch', via: 'change', kind: 'search' });
  assert.ok(!JSON.stringify(seen[0]).includes('secret'));
});

test('only app shortcuts are tracked, not arbitrary modifier combos', () => {
  if (!JSDOM) return;
  const { win, doc, seen } = boot(`<div data-ui-zone="wall"><button id="save">s</button></div>`);
  doc.getElementById('save').dispatchEvent(new win.KeyboardEvent('keydown', { key: 's', metaKey: true, bubbles: true }));
  doc.getElementById('save').dispatchEvent(new win.KeyboardEvent('keydown', { key: 'c', metaKey: true, bubbles: true }));
  assert.equal(seen.length, 1);
  assert.deepEqual(plain(seen[0].payload), { zone: 'wall', action: 'shortcut', target: 'cmd+s', via: 'key' });
});

test('manual track() emits through the same sink', () => {
  if (!JSDOM) return;
  const { win, seen } = boot('<div data-ui-zone="wall"></div>');
  win.ClipUiTrack.track('archive', 'open', 'reader', { via: 'api' });
  assert.deepEqual(plain(seen[0].payload), { zone: 'archive', action: 'open', target: 'reader', via: 'api' });
});
