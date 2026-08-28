/**
 * ClipVault Trae sessions UI: copy session id without selecting the card.
 * Run: node --test tests/sessions-ui.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const htmlPath = path.join(__dirname, '../trae_hooks/web/sessions.html');
const html = fs.readFileSync(htmlPath, 'utf8');

function extractInlineScripts(src) {
  const scripts = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const body = m[1].trim();
    if (body) scripts.push(body);
  }
  return scripts;
}

test('sessions.html inline module passes node --check', () => {
  const scripts = extractInlineScripts(html);
  assert.ok(scripts.length >= 1, 'expected inline module script');
  const main = scripts.reduce((a, b) => (a.length >= b.length ? a : b));
  const tmp = path.join(__dirname, '../.tmp-sessions-main.mjs');
  fs.writeFileSync(tmp, main);
  const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
  try { fs.unlinkSync(tmp); } catch (_) {}
  assert.equal(r.status, 0, `SyntaxError in sessions.html:\n${r.stderr || r.stdout}`);
});

test('list and detail can copy session id', () => {
  assert.match(html, /id="sessionHead"/);
  assert.match(html, /id="copySid"/);
  assert.match(html, /data-copy-sid=/);
  assert.match(html, /title="复制 session id"/);
  assert.match(html, /const copySessionId = async/);
  assert.match(html, /navigator\.clipboard\.writeText/);
  assert.match(html, /ev\.stopPropagation\(\)/);
  assert.match(html, /bindCopyButtons\(box\)/);
  assert.match(html, /copySessionId\(current, \$ \("copySid"\)\)|copySessionId\(current, \$\("copySid"\)\)/);
});

test('copy button press feedback stays short and origin-safe', () => {
  assert.match(html, /\.copy-id:active \{ transform: scale\(0\.97\)/);
  assert.match(
    html,
    /@media \(hover: hover\) and \(pointer: fine\) \{[\s\S]*?\.copy-id:hover/,
  );
  assert.doesNotMatch(html, /data-copy-sid=\"\$\{s\.session_id\}/);
});
