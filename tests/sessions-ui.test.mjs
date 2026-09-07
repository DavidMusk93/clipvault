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

test('rail and thread are separate scroll layers', () => {
  assert.match(html, /html, body \{[\s\S]*?overflow:\s*hidden/);
  assert.match(html, /#sessionList \{[\s\S]*?overflow-y:\s*auto/);
  assert.match(html, /\.thread \{[\s\S]*?overflow-y:\s*auto/);
  assert.match(html, /overscroll-behavior:\s*contain/);
  assert.match(html, /id="thread"/);
  assert.match(html, /id="sessionList"/);
  assert.doesNotMatch(html, /min-height:\s*calc\(100vh/);
});

test('new events follow the thread tail unless the user scrolled up', () => {
  assert.match(html, /followTail/);
  assert.match(html, /pinBottomSoon/);
  assert.match(html, /nearBottom/);
  assert.match(html, /id="jumpBot"/);
  assert.match(html, /pendingNew/);
  assert.match(html, /sig\.startsWith\(lastSig/);
  assert.doesNotMatch(html, /id="jumpTop"/);
});

test('chat chrome: tool fold, no shared bubble max-height on user', () => {
  assert.match(html, /tool-fold/);
  assert.match(html, /\.bubble\.tool \.bubble-body \{[\s\S]*?max-height/);
  assert.doesNotMatch(html, /\.bubble-body \{\s*max-height:\s*min\(280px/);
  assert.match(html, /sessionTitle/);
});

test('session list asks the store for last_prompt', () => {
  const server = fs.readFileSync(path.join(__dirname, '../trae_hooks/server.py'), 'utf8');
  assert.match(server, /last_prompt/);
  assert.match(html, /s\.last_prompt/);
});

test('opens the latest session and shows tool command without folding it away', () => {
  assert.match(html, /followLatest/);
  assert.match(html, /latest\.session_id/);
  assert.match(html, /const renderTool =/);
  assert.match(html, /tool-cmd/);
  assert.match(html, /展开输出/);
  assert.match(html, /blocksFromEvent/);
});

test('trae sessions use nmem SSE contract, not interval polling', () => {
  const server = fs.readFileSync(path.join(__dirname, '../trae_hooks/server.py'), 'utf8');
  assert.match(server, /path == \"\/api\/stream\"/);
  assert.match(server, /retry: 3000/);
  assert.match(server, /X-Accel-Buffering/);
  assert.match(server, /SSE_MAX_BUFFERED = 32/);
  assert.match(server, /SSE_HEARTBEAT_SECONDS = 15/);
  assert.match(server, /resync_required/);
  assert.match(server, /: ping/);
  assert.match(html, /EventSource\(\"\/api\/stream\"\)/);
  assert.match(html, /resync_required/);
  assert.match(html, /scheduleResync/);
  assert.match(html, /visibilitychange/);
  assert.match(html, /pageshow/);
  assert.doesNotMatch(html, /setInterval\(/);
  assert.doesNotMatch(
    html,
    /es\.close\(\);\s*setTimeout\(setupSSE/,
  );
  assert.match(html, /EventSource\.CLOSED/);
});

test('unchanged poll must not pinBottom; jitter is traced via ui-metrics', () => {
  assert.doesNotMatch(html, /if \(sig === lastSig\) \{\s*if \(followTail\) pinBottomSoon/);
  assert.match(html, /if \(sig === lastSig\) return/);
  assert.match(html, /if \(listSig === lastListSig\) return/);
  assert.match(html, /trae_sessions_cls/);
  assert.match(html, /trae_sessions_paint/);
  assert.match(html, /trae_sessions_longtask/);
  assert.match(html, /127\.0\.0\.1:8080\/api\/ui-metrics/);
});
