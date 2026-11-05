/**
 * Archive reader chrome — TOC + SQLite learning traces.
 * Run: node --test tests/archive-reader.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { src, root } from './helpers/src.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const js = fs.readFileSync(path.join(__dirname, '../web/assets/archive-reader.js'), 'utf8');
const swiftWeb = src('WebServer.swift');
const swiftDb = src('DatabaseManager.swift');

test('reader chrome talks to SQLite via same-origin API', () => {
  assert.match(js, /\/api\/archive\/reader/, 'reader API');
  assert.match(js, /highlight_add/, 'highlight op');
  assert.match(js, /scroll_checkpoint/, 'resume op');
  assert.match(js, /headingOffset/, 'resume stores offset inside the chapter');
  assert.match(js, /caretRangeFromPoint|caretPositionFromPoint/, 'reading-line caret');
  assert.match(js, /function resolvePosY/, 'restore prefers quote then chapter offset');
  assert.match(js, /function captureAnchor/, 'checkpoint captures a text anchor');
  assert.match(js, /comment/, 'comment op');
  assert.match(js, /collectHeadings/, 'TOC still derived');
});

test('selection chrome is a glass bar that never covers the rect', () => {
  assert.match(js, /function placeNearRect/, 'placement helper');
  assert.match(js, /Never cover the rect/, 'never-cover contract');
  assert.match(js, /opts.prefer \|\| "above"/, 'selection prefers above');
  assert.match(js, /class="cv-caret"/, 'caret points at selection');
  assert.match(js, /backdrop-filter:blur\(40px\)/, 'macOS glass material');
  assert.match(js, /cv-swatch/, 'highlight mapped to a color well');
  assert.match(js, /划线/, 'highlight action');
  assert.match(js, /评论/, 'comment action');
  assert.match(js, /is-sheet/, 'narrow viewport uses a sheet');
  assert.match(js, /allowSide/, 'wide viewport parks the note in the margin');
  assert.match(swiftWeb, /archive-reader\.js\?v=20261105a/, 'cache bust');
  assert.match(js, /function wrapCallouts/, 'nested article callouts');
  assert.match(js, /function enhanceTechnicalMedia/, 'code/figure plate is View-time');
  assert.match(js, /data-cv-enhance/, 'fixture can run media enhance without reader API');
  assert.match(js, /function promoteLazyImages/, 'weixin data-src → src');
  assert.match(js, /dblclick/, 'double-click mark opens comment');
  assert.match(js, /cv-note-kicker/, 'header title is a span, not a nested lead');
  assert.match(js, /line-height:28px/, 'header text and buttons share one strut');
  assert.match(js, /cv-note-tools/, 'header actions on the right');
  assert.match(js, /cv-hist-rail/, 'reddit-style thread rail');
  assert.match(js, /写下一句想法/, 'same copy as card evaluation');
});

test('highlight_delete must not reuse the highlight UUID as reader_ops PK', () => {
  assert.match(
    swiftDb,
    /delete \/ comment \/ update MUST get a fresh row id/,
    'delete/comment cannot collide with highlight_add row'
  );
  assert.match(js, /highlight_delete/, 'client posts delete');
  assert.match(js, /function sameHlId/, 'id compare is case-insensitive');
});

test('delete highlight lives on the selection bar, not the comment sheet', () => {
  assert.match(js, /className = "cv-del"/, 'delete is a selbar action');
  assert.match(js, /has-hl/, 'existing highlight switches the bar');
  assert.doesNotMatch(js, /删除划线/, 'no 删除划线 inside the comment sheet');
});

test('reader comment sheet lists append-only ops as a timeline', () => {
  assert.match(js, /function opsForHighlight/, 'filter ops per highlight');
  assert.match(js, /cv-hist/, 'history list');
  assert.match(js, />记录</, '记录 title');
  assert.match(swiftWeb, /"ops": bundle\.ops/, 'POST returns ops');
  assert.match(swiftDb, /timeLocal/, 'ops carry wall time');
});

test('newline inside a text node still paints the collapsed quote', async (t) => {
  const { JSDOM } = await import('jsdom');
  const sentence = 'By default, DataFusion already does not add bloom filters when writing Parquet files.';
  const broken = sentence.replace(' when writing ', ' when\nwriting ');
  const dom = new JSDOM(
    `<!DOCTYPE html><html data-cv-test><body><main class="cv-article">` +
      `<p>BEFORE ${broken} AFTER</p>` +
      `<p>Later note: ${broken} END</p>` +
      `<p>AAA same\nwords BBB same words CCC</p>` +
      `<p>keep  double spaces</p>` +
    `</main></body></html>`,
    { runScripts: 'outside-only', url: 'http://127.0.0.1/api/archive/view' }
  );
  t.after(() => dom.window.close());
  dom.window.eval(js);
  const api = dom.window.__cvReaderTest;
  const root = dom.window.document.querySelector('main.cv-article');
  const idx = api.buildIndex(root);
  assert.match(root.querySelector('p').firstChild.nodeValue, /when\nwriting/);

  const first = api.locateQuote(idx, sentence, 'BEFORE ', ' AFTER');
  assert.equal(idx.text.slice(first.start, first.end), broken);
  const second = api.locateQuote(idx, sentence, 'Later note: ', ' END');
  assert.equal(idx.text.slice(second.start, second.end), broken);
  assert.ok(second.start > first.start);
  assert.equal(api.locateQuote(idx, sentence, 'BEFORE ', ' END'), null);
  assert.equal(api.locateQuote(idx, sentence, 'ZZZ_NO_MATCH_', ''), null);
  assert.equal(api.locateQuote(idx, '   ', '', ''), null);
  assert.equal(api.locateQuote(idx, '', '', ''), null);
  assert.equal(api.locateQuote(idx, 'this sentence is not in the article', '', ''), null);

  assert.equal(idx.text.slice(api.locateQuote(idx, 'same words', 'BBB ', '').start,
    api.locateQuote(idx, 'same words', 'BBB ', '').end), 'same words');
  assert.equal(idx.text.slice(api.locateQuote(idx, 'same words', 'AAA ', '').start,
    api.locateQuote(idx, 'same words', 'AAA ', '').end), 'same\nwords');
  const doubled = api.locateQuote(idx, 'keep double spaces', '', '');
  assert.equal(idx.text.slice(doubled.start, doubled.end), 'keep  double spaces');

  api.applyHighlights(root, [{ id: 'h-nl', quote: sentence, prefix: 'BEFORE ', suffix: ' AFTER' }]);
  const marks = [...root.querySelectorAll('mark.cv-hl')];
  assert.equal(marks.length, 1);
  assert.equal(marks[0].dataset.hlId, 'h-nl');
  assert.equal(marks[0].textContent, broken);
  assert.match(marks[0].textContent, /when\nwriting/);
});

test('a highlight is the selected range, including its own whitespace', async (t) => {
  const { JSDOM } = await import('jsdom');
  const sentence = '\nBy default, DataFusion already does not add bloom filters when\nwriting Parquet files.\n';
  const dom = new JSDOM(
    '<!DOCTYPE html><html data-cv-test><body><main class="cv-article">' +
      '<p id="edge"></p>' +
      '<p id="break">when<br>writing</p>' +
      '<p id="one">alpha</p><p id="two">beta</p>' +
    '</main></body></html>',
    { runScripts: 'outside-only', url: 'http://127.0.0.1/api/archive/view' }
  );
  t.after(() => dom.window.close());
  const { document } = dom.window;
  const edge = document.getElementById('edge');
  edge.appendChild(document.createTextNode('BEFORE'));
  const body = document.createTextNode(sentence);
  edge.appendChild(body);
  edge.appendChild(document.createTextNode('AFTER'));
  dom.window.eval(js);
  const api = dom.window.__cvReaderTest;
  const root = document.querySelector('main.cv-article');

  const whole = document.createRange();
  whole.setStart(body, 0);
  whole.setEnd(body, body.nodeValue.length);
  const sel = dom.window.getSelection();
  sel.removeAllRanges();
  sel.addRange(whole);
  const saved = api.serializeSelection(root);
  assert.equal(saved.quote, sentence);
  assert.equal(saved.prefix.slice(-6), 'BEFORE');
  assert.equal(saved.suffix.slice(0, 5), 'AFTER');
  const idx = api.buildIndex(root);
  const abs = api.rangeToAbs(idx, whole);
  assert.equal(idx.text.slice(abs.start, abs.end), whole.toString());
  api.applyHighlights(root, [saved && { id: 'edge', quote: saved.quote, prefix: saved.prefix, suffix: saved.suffix }]);
  const edgeMarks = [...edge.querySelectorAll('mark.cv-hl')];
  assert.equal(edgeMarks.length, 1);
  assert.equal(edgeMarks[0].textContent, sentence);

  const broken = document.getElementById('break');
  const across = document.createRange();
  across.selectNodeContents(broken);
  sel.removeAllRanges();
  sel.addRange(across);
  const brSaved = api.serializeSelection(root);
  assert.equal(brSaved.quote, 'when\nwriting');
  api.applyHighlights(root, [{ id: 'br', quote: brSaved.quote, prefix: brSaved.prefix, suffix: brSaved.suffix }]);
  const pieces = [...broken.querySelectorAll('mark.cv-hl')].map((m) => m.textContent);
  assert.deepEqual(pieces, ['when', 'writing']);

  const cross = document.createRange();
  cross.setStart(document.getElementById('one'), 0);
  cross.setEnd(document.getElementById('two'), document.getElementById('two').childNodes.length);
  sel.removeAllRanges();
  sel.addRange(cross);
  assert.equal(cross.commonAncestorContainer, root);
  const crossSaved = api.serializeSelection(root);
  assert.equal(crossSaved.quote, cross.toString());
  assert.match(crossSaved.quote, /alpha/);
  assert.match(crossSaved.quote, /beta/);
});

test('server persists reader_state + reader_ops, not archive HTML', () => {
  assert.match(swiftDb, /CREATE TABLE IF NOT EXISTS reader_ops/, 'ops table');
  assert.match(swiftDb, /reader_state/, 'projection column');
  assert.match(swiftWeb, /\/api\/archive\/reader/, 'HTTP surface');
  assert.match(swiftWeb, /connect-src 'self'/, 'view document may POST');
  assert.match(swiftWeb, /\/assets\/archive-reader\.js/, 'same-origin script');
});
