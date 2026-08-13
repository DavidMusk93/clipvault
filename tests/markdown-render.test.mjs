/**
 * Markdown preview uses marked + DOMPurify only (no DIY grammar).
 * Run: node --test tests/markdown-render.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { renderMarkdownToHtml, neutralizeAnchorsHtml } from '../web/markdown-render.mjs';
import { formatTextForDisplay } from '../web/text-format.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexHtml = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const require = createRequire(import.meta.url);

let marked;
let purify;
try {
  marked = require('marked');
} catch (_) {
  marked = null;
}
try {
  // jsdom optional for full purify in node
  purify = null;
} catch (_) {}

test('index loads marked + DOMPurify CDN (mature libs)', () => {
  assert.match(indexHtml, /marked@|marked\.min\.js/, 'must load marked');
  assert.match(indexHtml, /dompurify|purify\.min\.js/i, 'must load DOMPurify');
  assert.match(indexHtml, /md-preview/, 'must have preview surface');
  assert.match(indexHtml, /renderMarkdownPreviewHtml/, 'preview entry');
  // no giant DIY fence grammar in index (fallback was removed intentionally)
  assert.doesNotMatch(indexHtml, /fallbackMarkdownToHtml/, 'no home-grown markdown parser');
});

test('without libs, render refuses DIY and returns ok:false', () => {
  const r = renderMarkdownToHtml('# Hi\n\n- a\n', {});
  assert.equal(r.ok, false);
  assert.equal(r.html, '');
});

test('formatTextForDisplay still detects markdown kind', () => {
  const f = formatTextForDisplay('# Title\n\n- item one\n- item two\n\n```js\nok\n```');
  assert.equal(f.kind, 'markdown');
});

test('neutralizeAnchorsHtml strips navigable anchors', () => {
  const out = neutralizeAnchorsHtml('<p>see <a href="https://example.com">x</a></p>');
  assert.ok(!/<a\b/i.test(out), out);
  assert.match(out, /url-inert|md-link|example|x/i);
});
