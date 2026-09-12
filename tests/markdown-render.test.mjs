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
import { renderMarkdownToHtml, neutralizeAnchorsHtml, renderMarkdownBlocks, compileMarkdownBlocks, resetMarkdownCompileCache, hashMarkdownToken, toGfmNestedLists, mapLineToScrollTop, mapScrollTopToLine, mapSourceToPreviewScroll, mapPreviewToSourceLine, tokenLineSpan, countNewlinesInRange } from '../web/markdown-render.mjs';
import { previewWindow, PREVIEW_WINDOW_MIN } from '../web/notes-preview-window.mjs';
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

test('toGfmNestedLists maps indented a./i. to 1. and leaves column-0 prose', () => {
  const src = '1. foo\n    a. bar\n    b. baz\n        i. nest\ni.e. not a list\n';
  const out = toGfmNestedLists(src);
  assert.match(out, /    1\. bar/);
  assert.match(out, /    1\. baz/);
  assert.match(out, /        1\. nest/);
  assert.match(out, /i\.e\. not a list/);
  assert.doesNotMatch(out, /^\s*a\./m);
});

test('renderMarkdownBlocks refuses without engines', () => {
  const r = renderMarkdownBlocks('# Hi\n\npara\n', {});
  assert.equal(r.ok, false);
});

function fakeMarkdownEngines() {
  return {
    marked: {
      setOptions() {},
      lexer(text) {
        const tokens = [];
        const parts = String(text).split(/(?<=\n\n)/);
        for (const raw of parts) {
          if (!raw || !raw.trim()) continue;
          if (raw.startsWith('# ')) tokens.push({ type: 'heading', raw });
          else tokens.push({ type: 'paragraph', raw });
        }
        return tokens;
      },
      parser(toks) {
        const t = toks[0];
        const body = String(t.raw || '').replace(/\n+$/, '');
        if (t.type === 'heading') {
          const m = /^(#+)\s*([\s\S]*)$/.exec(body);
          const d = m ? m[1].length : 1;
          const title = m ? m[2] : body;
          return `<h${d}>${title}</h${d}>`;
        }
        return `<p>${body}</p>`;
      },
    },
    purify: { sanitize: (html) => html },
  };
}

test('compileMarkdownBlocks does not re-split the document prefix per token', () => {
  const src = fs.readFileSync(path.join(__dirname, '../web/markdown-render.mjs'), 'utf8');
  assert.doesNotMatch(src, /text\.slice\(0,\s*at\)\.split\(/);
  assert.match(src, /countNewlinesInRange/);
  assert.equal(countNewlinesInRange('a\nb\nc', 0, 5), 2);
  assert.equal(countNewlinesInRange('a\nb\nc', 2, 4), 1);
});

test('compileMarkdownBlocks line numbers stay sequential on a long list', () => {
  resetMarkdownCompileCache();
  const engines = fakeMarkdownEngines();
  const body = Array.from({ length: 80 }, (_, i) => `para ${i}\n\n`).join('');
  const r = compileMarkdownBlocks(body, engines);
  assert.equal(r.ok, true);
  assert.equal(r.blocks.length, 80);
  assert.equal(r.blocks[0].lineFrom, 1);
  assert.ok(r.blocks[79].lineFrom > r.blocks[0].lineFrom);
  for (let i = 1; i < r.blocks.length; i++) {
    assert.ok(r.blocks[i].lineFrom >= r.blocks[i - 1].lineFrom);
  }
});

test('previewWindow keeps small notes unwindowed and long notes sparse', () => {
  const small = previewWindow(0, 800, 10, []);
  assert.equal(small.from, 0);
  assert.equal(small.to, 10);
  assert.equal(small.padTop, 0);
  const n = PREVIEW_WINDOW_MIN + 40;
  const heights = Array(n).fill(80);
  const mid = previewWindow(800, 400, n, heights, 80, 2);
  assert.ok(mid.from > 0);
  assert.ok(mid.to < n);
  assert.ok(mid.to - mid.from < n);
  assert.ok(mid.padTop > 0);
  assert.ok(mid.padBottom > 0);
});

test('compileMarkdownBlocks reuses unchanged token HTML by hash', () => {
  resetMarkdownCompileCache();
  const engines = fakeMarkdownEngines();
  const a = compileMarkdownBlocks('# Hi\n\nfoo\n\nbar\n', engines);
  assert.equal(a.ok, true);
  assert.equal(a.blocks.length, 3);
  assert.equal(a.stats.compiled, 3);
  assert.equal(a.stats.reused, 0);
  assert.equal(typeof a.stats.dur_ms, 'number');
  assert.ok(a.stats.dur_ms >= 0);
  assert.doesNotMatch(a.blocks[0].html, /data-source-line/);
  assert.equal(a.blocks[0].lineFrom, 1);
  assert.match(a.blocks[0].key, /^[0-9a-f]+:0$/);

  const b = compileMarkdownBlocks('# Hi\n\nfoo!\n\nbar\n', engines);
  assert.equal(b.blocks.length, 3);
  assert.equal(b.stats.compiled, 1);
  assert.equal(b.stats.reused, 2);
  assert.equal(a.blocks[0].hash, b.blocks[0].hash);
  assert.equal(a.blocks[2].hash, b.blocks[2].hash);
  assert.notEqual(a.blocks[1].hash, b.blocks[1].hash);
});

test('compileMarkdownBlocks hash ignores source line so insert-above reuses', () => {
  resetMarkdownCompileCache();
  const engines = fakeMarkdownEngines();
  const a = compileMarkdownBlocks('# Hi\n\nhello\n', engines);
  const b = compileMarkdownBlocks('# New\n\n# Hi\n\nhello\n', engines);
  const helloA = a.blocks.find((x) => x.html.includes('hello'));
  const helloB = b.blocks.find((x) => x.html.includes('hello'));
  assert.ok(helloA && helloB);
  assert.equal(helloA.hash, helloB.hash);
  assert.notEqual(helloA.lineFrom, helloB.lineFrom);
  assert.equal(helloA.key, `${helloA.hash}:0`);
  assert.equal(hashMarkdownToken('heading', '# Hi\n\n'), hashMarkdownToken('heading', '# Hi\n\n'));
});

test('mapLineToScrollTop interpolates anchors and falls back proportionally', () => {
  assert.equal(mapLineToScrollTop(1, [], 10, 100), 0);
  assert.equal(mapLineToScrollTop(10, [], 10, 100), 100);
  assert.equal(mapLineToScrollTop(6, [], 11, 100), 50);
  const anchors = [{ line: 5, y: 20 }, { line: 15, y: 80 }];
  assert.equal(mapLineToScrollTop(5, anchors, 20, 100), 20);
  assert.equal(mapLineToScrollTop(10, anchors, 20, 100), 50);
  assert.equal(mapLineToScrollTop(20, anchors, 20, 100), 100);
  assert.equal(mapLineToScrollTop(1, anchors, 20, 0), 0);
});

test('mapScrollTopToLine is the inverse of mapLineToScrollTop', () => {
  const anchors = [{ line: 5, y: 20 }, { line: 15, y: 80 }];
  const y = mapLineToScrollTop(10, anchors, 20, 100);
  const back = mapScrollTopToLine(y, anchors, 20, 100);
  assert.ok(Math.abs(back - 10) < 1e-6, back);
  assert.equal(mapScrollTopToLine(0, [], 10, 100), 1);
  assert.equal(mapScrollTopToLine(100, [], 10, 100), 10);
});

test('tokenLineSpan covers fence bodies and single-line tokens', () => {
  assert.equal(tokenLineSpan('# Hi\n', 1), 1);
  assert.equal(tokenLineSpan('```js\nfoo\nbar\n```\n', 10), 13);
  assert.equal(tokenLineSpan('para', 4), 4);
});

test('mapSourceToPreviewScroll pins ends and interpolates inside fences', () => {
  const blocks = [
    { lineFrom: 1, lineTo: 1, y: 0, height: 40 },
    { lineFrom: 3, lineTo: 12, y: 80, height: 200 },
    { lineFrom: 14, lineTo: 14, y: 320, height: 30 },
  ];
  const opts = { lastLine: 20 };
  assert.equal(mapSourceToPreviewScroll(1, blocks, 400, opts), 0);
  assert.equal(mapSourceToPreviewScroll(20, blocks, 400, { ...opts, atEnd: true }), 400);
  assert.equal(mapSourceToPreviewScroll(20, blocks, 400, opts), 400);
  assert.equal(mapSourceToPreviewScroll(7.5, blocks, 400, opts), 180);
  const between = mapSourceToPreviewScroll(2, blocks, 400, opts);
  assert.equal(between, 60);
});

test('mapPreviewToSourceLine is the inverse inside a fence', () => {
  const blocks = [
    { lineFrom: 1, lineTo: 1, y: 0, height: 40 },
    { lineFrom: 3, lineTo: 12, y: 80, height: 200 },
    { lineFrom: 14, lineTo: 14, y: 320, height: 30 },
  ];
  const y = mapSourceToPreviewScroll(7.5, blocks, 400, { lastLine: 20 });
  const back = mapPreviewToSourceLine(y, blocks, 400, 20);
  assert.ok(Math.abs(back - 7.5) < 1e-6, back);
  assert.equal(mapPreviewToSourceLine(0, blocks, 400, 20), 1);
  assert.equal(mapPreviewToSourceLine(400, blocks, 400, 20, { atEnd: true }), 20);
});

test('this file is in the deploy frontend gate', () => {
  const check = fs.readFileSync(path.join(__dirname, '../scripts/check-frontend.sh'), 'utf8');
  assert.match(check, /markdown-render\.test\.mjs/);
});

test('neutralizeAnchorsHtml strips navigable anchors', () => {
  const out = neutralizeAnchorsHtml('<p>see <a href="https://example.com">x</a></p>');
  assert.ok(!/<a\b/i.test(out), out);
  assert.match(out, /url-inert|md-link|example|x/i);
});
