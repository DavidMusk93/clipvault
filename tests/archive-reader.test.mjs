/**
 * Archive reader chrome — runtime TOC + local progress store.
 * Run: node --test tests/archive-reader.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const jsPath = path.join(__dirname, '../web/assets/archive-reader.js');
const swiftPath = path.join(__dirname, '../ClipFlow/WebServer.swift');
const js = fs.readFileSync(jsPath, 'utf8');
const swift = fs.readFileSync(swiftPath, 'utf8');

test('reader script is a same-origin asset, not inline in the article', () => {
  assert.match(js, /clipvault-reader/, 'IndexedDB name');
  assert.match(js, /collectHeadings/, 'TOC from live headings');
  assert.match(js, /indexedDB/, 'browser local DB');
  assert.match(js, /localStorage/, 'fallback store');
  assert.doesNotMatch(js, /clipflow\.db|indexedDB\.open\(\s*['\"]clipflow/i, 'never open the capture SQLite');
});

test('view document loads reader script and relaxes only script-src self', () => {
  assert.match(swift, /\/assets\/archive-reader\.js/, 'script tag');
  assert.match(swift, /data-archive-id/, 'stable key on html');
  assert.match(swift, /script-src 'self'/, 'allow same-origin reader only');
  assert.doesNotMatch(swift, /script-src 'none'/, 'old lock would kill TOC');
});
