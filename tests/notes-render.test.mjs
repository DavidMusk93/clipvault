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

test('index.html CSS: Notes prose must not force white-space:pre on all blocks', () => {
  // Regression: 3c37f48 applied white-space:pre to all notes p/li/div → blank lines + non-Notes look
  const bad = /\.notes-rich p,\s*\.snippet-html p,\s*\.notes-rich li,\s*\.snippet-html li,\s*\.notes-rich div,\s*\.snippet-html div\s*\{[^}]*white-space:\s*pre\s*;/s;
  assert.equal(bad.test(indexHtml), false, 'global pre on notes blocks is forbidden');
  if (NOTES_CSS_POLICY.requireEmptyPHidden) {
    assert.match(indexHtml, /\.notes-rich p:empty/);
  }
  if (NOTES_CSS_POLICY.requireMonoPre) {
    assert.match(indexHtml, /\.notes-rich[^\n]*\.is-mono|is-mono[^{]*\{[^}]*white-space:\s*pre/s);
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
