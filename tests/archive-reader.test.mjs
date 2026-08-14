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

test('server persists reader_state + reader_ops, not archive HTML', () => {
  assert.match(swiftDb, /CREATE TABLE IF NOT EXISTS reader_ops/, 'ops table');
  assert.match(swiftDb, /reader_state/, 'projection column');
  assert.match(swiftWeb, /\/api\/archive\/reader/, 'HTTP surface');
  assert.match(swiftWeb, /connect-src 'self'/, 'view document may POST');
  assert.match(swiftWeb, /\/assets\/archive-reader\.js/, 'same-origin script');
});
