/**
 * Notes-like rich HTML regression tests.
 * Run: node --test tests/notes-render.test.mjs tests/masonry.test.mjs tests/pagination.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  renderNotesFragment,
  collapseEmptyHtmlBlocks,
  stripHtmlToText,
  notesFragmentUseful,
  NOTES_CSS_POLICY,
} from '../web/notes-render.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexHtml = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');

test('collapseEmptyHtmlBlocks removes empty p/div/li holes', () => {
  const html = `
    <p>Hello</p>
    <p><br></p>
    <p>&nbsp;</p>
    <p> <span></span> </p>
    <p>World</p>
    <br><br><br>
  `;
  const out = collapseEmptyHtmlBlocks(html);
  assert.match(out, /Hello/);
  assert.match(out, /World/);
  assert.equal((out.match(/<p[\s>]/g) || []).length, 2);
  assert.ok(!/<p[^>]*>\s*<br/i.test(out));
});

test('Cocoa-ish spacer soup does not leave blank paragraph stack', () => {
  const cocoa = `
  <html><body>
    <p class="p1"><span class="s1"></span></p>
    <p class="p1"><span class="Apple-converted-space">&nbsp;</span></p>
    <p class="p1">卡片上的事件时间</p>
    <p class="p1"><br></p>
    <p class="p1"><br class="Apple-interchange-newline"></p>
    <p class="p1">第二段正文</p>
  </body></html>`;
  const frag = renderNotesFragment(cocoa);
  assert.ok(notesFragmentUseful(frag));
  const plain = stripHtmlToText(frag);
  assert.match(plain, /卡片上的事件时间/);
  assert.match(plain, /第二段正文/);
  // not a pile of empty lines
  assert.ok(!/\n{4,}/.test(plain));
  const pCount = (frag.match(/<p[\s>]/g) || []).length;
  assert.ok(pCount <= 3, `expected few p tags, got ${pCount}: ${frag}`);
});

test('list structure is preserved', () => {
  const html = '<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>';
  const frag = renderNotesFragment(html);
  assert.match(frag, /<ul>/i);
  assert.match(frag, /<li>/i);
  assert.match(frag, /nested/);
});

test('notesFragmentUseful rejects pure empty chrome', () => {
  assert.equal(notesFragmentUseful('<p><br></p><p>&nbsp;</p>'), false);
  assert.equal(notesFragmentUseful('<p>hi</p>'), true);
});

test('index.html CSS: rich text must not soft-wrap (pre + pan)', () => {
  // Product: dont wrap lines — pan instead. Empty holes are JS cleanup, not soft-wrap.
  // Multi-selector block may span >120 chars before white-space; allow a generous window.
  // Prose: normal wrap (blank-line friendly). Mono remains pre (see .is-mono).
  assert.match(
    indexHtml,
    /\.notes-rich p[\s\S]{0,400}?white-space:\s*normal\s*;/,
    'notes-rich p prose uses white-space:normal',
  );
  assert.match(
    indexHtml,
    /\.notes-rich \.is-mono[\s\S]{0,200}?white-space:\s*pre/,
    'notes-rich mono keeps white-space:pre',
  );
  assert.match(indexHtml, /\.notes-rich-inner[\s\S]{0,120}?width:\s*max-content/);
  assert.doesNotMatch(
    indexHtml,
    /\.notes-rich, \.snippet-html \{[\s\S]{0,300}?overflow-wrap:\s*anywhere/,
    'notes container must not force overflow-wrap:anywhere',
  );
  if (NOTES_CSS_POLICY.requireEmptyPHidden) {
    assert.match(indexHtml, /\.notes-rich p:empty/);
  }
  if (NOTES_CSS_POLICY.requireMonoPre) {
    assert.match(indexHtml, /is-mono[\s\S]{0,120}?white-space:\s*pre/);
  }
  if (NOTES_CSS_POLICY.requireNotesInnerMaxContent) {
    assert.match(indexHtml, /\.notes-rich-inner[\s\S]{0,120}?width:\s*max-content/);
  }
});

test('index.html uses notes-render pipeline helpers (sync guard)', () => {
  // Ensure live page still has Notes path hooks
  assert.match(indexHtml, /function renderNotesFragment/);
  assert.match(indexHtml, /notesFragmentUseful/);
  assert.match(indexHtml, /notes-rich/);
});

test('plain text path stays unwrap for is-single (not notes)', () => {
  assert.match(indexHtml, /\.card-body \.text-scroll\.is-single pre code/);
  assert.match(indexHtml, /white-space:\s*pre;\s*\/\* no soft wrap/);
});

test('Chrome dark paint styles are stripped (no black cards)', () => {
  const html = `<html><body>
    <span style="background-color: rgb(0, 0, 0); color: rgb(255, 255, 255)">DSOD-062</span>
    <font bgcolor="#000000" color="#ffffff">code</font>
    <p style="background:black;color:white">x</p>
  </body></html>`;
  const frag = renderNotesFragment(html);
  assert.ok(!/background/i.test(frag), frag);
  assert.ok(!/style=/i.test(frag), frag);
  assert.ok(!/bgcolor/i.test(frag), frag);
  assert.match(frag, /DSOD-062/);
});

test('anchors are neutralized (no navigable href)', () => {
  const html = '<p>see <a href="https://example.com/path">link</a> here</p>';
  const frag = renderNotesFragment(html);
  assert.ok(!/<a\b/i.test(frag), frag);
  assert.match(frag, /url-inert|link|example/i);
});
