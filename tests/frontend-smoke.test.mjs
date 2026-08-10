/**
 * ClipVault web smoke / syntax regression.
 * Catches deploy-breaking SyntaxError in web/index.html inline scripts.
 * Run: node --test tests/frontend-smoke.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexPath = path.join(__dirname, '../web/index.html');
const indexHtml = fs.readFileSync(indexPath, 'utf8');

function extractInlineScripts(html) {
  const scripts = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const body = m[1].trim();
    if (body) scripts.push(body);
  }
  return scripts;
}

test('index.html has balanced real script tags (ignore regex literals)', () => {
  // Only count HTML tags at line starts / outside long script bodies is hard;
  // extractInlineScripts must find at least one non-empty inline script.
  const scripts = extractInlineScripts(indexHtml);
  assert.ok(scripts.length >= 1, 'expected inline <script> bodies');
  const main = scripts.reduce((a, b) => (a.length >= b.length ? a : b));
  assert.ok(main.length > 1000, 'main app script too small — page may be truncated');
});

test('main inline script passes node --check (syntax gate)', () => {
  const scripts = extractInlineScripts(indexHtml);
  const main = scripts.reduce((a, b) => (a.length >= b.length ? a : b));
  const tmp = path.join(__dirname, '../.tmp-frontend-main.js');
  fs.mkdirSync(path.dirname(tmp), { recursive: true });
  fs.writeFileSync(tmp, main);
  const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
  try { fs.unlinkSync(tmp); } catch (_) {}
  assert.equal(r.status, 0, `SyntaxError in web/index.html:\n${r.stderr || r.stdout}`);
});

test('backup status anyAvail expression is not split by injects', () => {
  // Regression: quarkDiscovery inject once split
  //   const anyAvail = dests.some(...)
  //     || s.cloudDocsAvailable ...
  // into two statements → SyntaxError / dead page.
  assert.match(
    indexHtml,
    /const anyAvail = dests\.some\(d => d\.enabled && d\.available\)\s*\|\|\s*s\.cloudDocsAvailable\s*\|\|\s*s\.googleDriveAvailable\s*;/,
    'anyAvail must be one complete expression (|| cloud fallbacks attached)',
  );
  // Orphan trailing || must not exist as a free statement after quark block
  assert.doesNotMatch(
    indexHtml,
    /\}\s*\n\s*\|\|\s*s\.cloudDocsAvailable/,
    'orphan || s.cloudDocsAvailable after a closing brace is a deploy-breaker',
  );
});

test('quarkDiscovery UI hooks stay wired', () => {
  assert.match(indexHtml, /id="bkQuarkDiscover"/);
  assert.match(indexHtml, /s\.quarkDiscovery/);
  assert.match(indexHtml, /card-header-lead/);
});

test('product brand is ClipVault in title', () => {
  assert.match(indexHtml, /<title>ClipVault<\/title>/);
});

test('html/rtf restores notes-rich for structure; plain uses hljs path', () => {
  assert.match(indexHtml, /notes-rich\$\{tiny\}/, 'structured HTML may use notes-rich');
  assert.match(indexHtml, /function looksLikeCode/);
  assert.match(indexHtml, /function detectCodeLang/);
  assert.match(indexHtml, /hljs\.highlightElement/);
  assert.match(indexHtml, /renderSearchableText|highlightEscaped/);
});

test('search highlight helpers present', () => {
  assert.match(indexHtml, /function highlightEscaped/);
  assert.match(indexHtml, /function fieldMatchesQuery/);
  assert.match(indexHtml, /search-hit/);
  assert.match(indexHtml, /命中 OCR/);
});

test('eval history note display does not soft-wrap', () => {
  assert.match(
    indexHtml,
    /\.eval-hist-note\s*\{[\s\S]{0,320}?white-space:\s*pre\s*;/,
    '备注展示 must use white-space:pre so real newlines stay obvious',
  );
  assert.doesNotMatch(
    indexHtml,
    /\.eval-hist-note\s*\{[\s\S]{0,200}?white-space:\s*pre-wrap/,
    'eval-hist-note must not use pre-wrap soft wrap',
  );
});

test('eval history note has copy button (scrollbar may obscure long lines)', () => {
  assert.match(indexHtml, /eval-hist-note-copy/);
  assert.match(indexHtml, /复制备注/);
  assert.match(
    indexHtml,
    /await copyClip\(noteText\)/,
    'note copy uses same macOS clipboard path as card copy',
  );
  assert.match(
    indexHtml,
    /\.eval-hist-note\s*\{[\s\S]{0,800}?padding:\s*2px 34px 14px 0/,
    'note body pads for copy chip + scrollbar so text is not covered',
  );
});
