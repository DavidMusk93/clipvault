/**
 * Archive reader chrome — TOC + SQLite learning traces.
 * Run: node --test tests/archive-reader.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const js = fs.readFileSync(path.join(__dirname, '../web/assets/archive-reader.js'), 'utf8');
const swiftWeb = fs.readFileSync(path.join(__dirname, '../ClipFlow/WebServer.swift'), 'utf8');
const swiftDb = fs.readFileSync(path.join(__dirname, '../ClipFlow/DatabaseManager.swift'), 'utf8');

test('reader chrome talks to SQLite via same-origin API', () => {
  assert.match(js, /\/api\/archive\/reader/, 'reader API');
  assert.match(js, /highlight_add/, 'highlight op');
  assert.match(js, /scroll_checkpoint/, 'resume op');
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
  assert.match(swiftWeb, /archive-reader\.js\?v=20260814h/, 'cache bust');
  assert.match(js, /写下一句想法/, 'same copy as card evaluation');
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

test('server persists reader_state + reader_ops, not archive HTML', () => {
  assert.match(swiftDb, /CREATE TABLE IF NOT EXISTS reader_ops/, 'ops table');
  assert.match(swiftDb, /reader_state/, 'projection column');
  assert.match(swiftWeb, /\/api\/archive\/reader/, 'HTTP surface');
  assert.match(swiftWeb, /connect-src 'self'/, 'view document may POST');
  assert.match(swiftWeb, /\/assets\/archive-reader\.js/, 'same-origin script');
});
