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
import { src, root } from './helpers/src.mjs';

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

test('list cards copy session id; thread header does not duplicate it', () => {
  assert.match(html, /id="sessionHead"/);
  assert.match(html, /data-copy-sid=/);
  assert.match(html, /title="复制 session id"/);
  assert.match(html, /const copySessionId = async/);
  assert.match(html, /navigator\.clipboard\.writeText/);
  assert.match(html, /ev\.stopPropagation\(\)/);
  assert.match(html, /bindCopyButtons\(el\)/);
  assert.doesNotMatch(html, /id="copySid"/);
  assert.match(html, /html\.embed \.session-head \{ display: none/);
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

test('session list pins locally and paints recency/volume in soft color', () => {
  const server = fs.readFileSync(path.join(__dirname, '../trae_hooks/server.py'), 'utf8');
  const schema = fs.readFileSync(path.join(__dirname, '../trae_hooks/schema.sql'), 'utf8');
  const swift = src('WebServer.swift');
  const taste = fs.readFileSync(path.join(__dirname, '../docs/design-taste.md'), 'utf8');
  const agents = fs.readFileSync(path.join(__dirname, '../AGENTS.md'), 'utf8');
  assert.match(schema, /CREATE TABLE IF NOT EXISTS session_pins/);
  assert.match(server, /path == \"\/api\/sessions\/pin\"/);
  assert.match(server, /def set_session_pin/);
  assert.match(server, /session_pinned/);
  assert.match(server, /LEFT JOIN session_pins/);
  assert.match(server, /\(p\.pinned_at IS NULL\) ASC/);
  assert.match(html, /const patchSessionList/);
  assert.match(html, /toggleSessionPin/);
  assert.match(html, /recencyTone/);
  assert.match(html, /volumeBand/);
  assert.match(html, /chip time/);
  assert.match(html, /chip vol/);
  assert.match(html, /tone-fresh/);
  assert.match(html, /\.card\.vol-l/);
  assert.match(html, /class="pin-btn"/);
  assert.match(html, /api\/sessions\/pin/);
  assert.doesNotMatch(html, /\/api\/clips\/pin/);
  assert.match(html, /newestSession/);
  assert.match(swift, /req\.httpMethod = method/);
  assert.match(swift, /req\.httpBody = data/);
  assert.match(taste, /会话列属性色/);
  assert.match(taste, /session_pins/);
  assert.match(agents, /POST \/api\/sessions\/pin/);
  assert.match(agents, /蜂蜜暖度/);
});

test('opens the latest session and shows tool command without folding it away', () => {
  assert.match(html, /followLatest/);
  assert.match(html, /latest\.session_id/);
  assert.match(html, /const renderTool =/);
  assert.match(html, /tool-cmd/);
  assert.match(html, /展开输出/);
  assert.match(html, /blocksFromEvent/);
});

test('user turns stay open; agent tools compress on the left', () => {
  assert.match(html, /focusImRows/);
  assert.match(html, /history-bundle/);
  assert.match(html, /function patchThread/);
  assert.match(html, /localDateTime/);
  assert.match(html, /relLocalTime/);
  assert.match(html, /renderAskBody/);
  assert.match(html, /row assistant/);
  assert.match(html, /history-item/);
  assert.match(html, /history-expand-all/);
  assert.match(html, /查看全部/);
  assert.match(html, /bindBundleExpand/);
  assert.match(html, /function patchThread/);
  assert.match(html, /function ingestHookIds/);
  assert.match(html, /function reconcile/);
  assert.match(html, /paintFromLive/);
  assert.doesNotMatch(html, /thread\.innerHTML = renderThread/);
  assert.match(html, /history-item-body"><\/div>/);
  assert.match(html, /\.history-item\[open\] \.history-item-body \{[^}]*position:\s*static/);
  assert.match(html, /dataset\.expandAll/);
  assert.doesNotMatch(html, /\.history-item\[open\] \.history-item-body \{[^}]*position:\s*absolute/);
});

test('AGENTS.md 墙 encodes UI incremental + lazy', () => {
  const agents = fs.readFileSync(path.join(__dirname, '../AGENTS.md'), 'utf8');
  const taste = fs.readFileSync(path.join(__dirname, '../docs/design-taste.md'), 'utf8');
  const wall = agents.split('## 墙')[1]?.split('## 笔记')[0] ?? '';
  assert.ok(wall.length > 0, 'missing ## 墙 … ## 笔记');
  assert.match(wall, /UI 增量 \+ lazy/);
  assert.match(wall, /lazy/);
  assert.match(wall, /脱离文档流/);
  assert.match(wall, /整树 `innerHTML`/);
  assert.match(agents, /bundle 正文 \*\*lazy\*\* 加载/);
  assert.match(taste, /禁止 `position:absolute` overlay/);
  assert.match(taste, /手风琴/);
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
  assert.match(html, /TRAE_BASE/);
  assert.match(html, /EventSource\(apiUrl\(\"\/api\/stream\"\)\)/);
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

test('server push carries needs_user for permission and ask', () => {
  const server = fs.readFileSync(path.join(__dirname, '../trae_hooks/server.py'), 'utf8');
  const client = fs.readFileSync(path.join(__dirname, '../trae_hooks/hook_client.py'), 'utf8');
  const row = fs.readFileSync(path.join(__dirname, '../trae_hooks/row.py'), 'utf8');
  assert.match(row, /NEEDS_USER_TYPES/);
  assert.match(row, /permission_prompt/);
  assert.match(server, /path != \"\/api\/notify\"/);
  assert.match(server, /needs_user/);
  assert.match(server, /sse_hook_payload/);
  assert.match(server, /hook_event IN \('UserPromptSubmit', 'Stop', 'Notification'\)/);
  assert.match(client, /def ping_sse/);
  assert.match(client, /ping_sse\(row\)/);
  assert.match(client, /ping_needs_user/);
  assert.match(client, /osascript/);
  assert.match(client, /\/api\/notify/);
  assert.doesNotMatch(server, /if existed and not needs_user_input/);
  assert.match(html, /scheduleHookPaint/);
});

test('sessions UI is prefix-aware so ClipVault :8080 can proxy /trae', () => {
  assert.match(html, /from \"\.\/session-render\.mjs\"/);
  assert.match(html, /location\.pathname\.startsWith\(\"\/trae\"\)/);
  assert.match(html, /html\.embed \.top/);
  assert.match(html, /classList\.add\(\"embed\"\)/);
  const server = src('WebServer.swift');
  assert.match(server, /func handleTraeProxy/);
  assert.match(server, /func traeBackendURL/);
  assert.match(server, /class TraeStreamPipe/);
  assert.match(server, /class TraeAskFanIn/);
  assert.match(server, /pathOnly == \"\/trae\"/);
});

test('unchanged poll must not pinBottom; jitter is traced via ui-metrics', () => {
  assert.doesNotMatch(html, /if \(sig === lastSig\) \{\s*if \(followTail\) pinBottomSoon/);
  assert.match(html, /if \(sig === lastSig && kind !== "full" && kind !== "settle"\) return/);
  assert.match(html, /if \(listSig === lastListSig\) return/);
  assert.match(html, /overflow-anchor:\s*none/);
  assert.match(html, /#threadEnd/);
  assert.match(html, /end\.id = "threadEnd"/);
  assert.match(html, /overflow-anchor:\s*auto/);
  assert.match(html, /kind === "patch" && grew/);
  assert.match(html, /function loadThreadPair/);
  assert.match(html, /takeLatest/);
  assert.match(html, /if \(!current\) \{/);
  assert.match(html, /loadEvents\("beats", \{ paint: false \}\)/);
  assert.match(html, /loadEvents\("tools", \{ paint: false \}\)/);
  assert.match(html, /paintFromLive\("pair"\)/);
  assert.doesNotMatch(html, /thread\.replaceChildren\(\)/);
  assert.doesNotMatch(html, /paintFromLive\("cache"\)/);
  assert.doesNotMatch(html, /thread\.innerHTML = '<div class="empty">没有匹配事件<\/div>';\n          lastSig/);
  assert.doesNotMatch(html, /requestAnimationFrame\(pinBottom\)/);
  assert.match(html, /trae_sessions_cls/);
  assert.match(html, /trae_sessions_md/);
  assert.match(html, /id="sessPerf"/);
  assert.match(html, /meterMd/);
  assert.match(html, /compiled\|reused/);
  assert.match(html, /phase: layoutReady \? "live" : "boot"/);
  assert.match(html, /trae_sessions_paint/);
  assert.match(html, /trae_sessions_longtask/);
  assert.match(html, /127\.0\.0\.1:8080\/api\/ui-metrics/);
});

test('session load coalesces hooks and omits bulky tool payloads from the list', () => {
  const server = fs.readFileSync(path.join(__dirname, '../trae_hooks/server.py'), 'utf8');
  const taste = fs.readFileSync(path.join(__dirname, '../docs/design-taste.md'), 'utf8');
  const agents = fs.readFileSync(path.join(__dirname, '../AGENTS.md'), 'utf8');
  assert.match(server, /view != \"beats\"/);
  assert.match(server, /list_cols =/);
  assert.match(server, /beat_cols =/);
  assert.match(server, /SELECT \{list_cols\}/);
  assert.match(server, /SELECT \{beat_cols\}/);
  assert.match(html, /eventsGen/);
  assert.match(html, /AbortController/);
  assert.match(html, /trae_sessions_load/);
  assert.match(html, /trae_sessions_error/);
  assert.match(html, /trae_sessions_list/);
  assert.match(html, /trae_sessions_ttfp/);
  assert.match(html, /trae_sessions_net/);
  assert.match(html, /trae_sessions_layout/);
  assert.match(html, /trae_sessions_skip/);
  assert.match(html, /clipvault-sessions-settled/);
  assert.match(html, /layoutNarrow/);
  assert.match(html, /paintGateReason/);
  assert.doesNotMatch(html, /if \(!layoutReady\) return "notready"/);
  assert.match(html, /emitLayout/);
  assert.match(html, /embedded/);
  assert.match(html, /b\.key === \"prompt\"/);
  assert.match(html, /name.startsWith\(\"trae_\"\)/);
  assert.match(html, /mergeIncoming/);
  assert.match(html, /params.set\(\"view\", kind\)/);
  assert.match(html, /if \(!pack.open && body.dataset.expandAll !== \"1\"\)/);
  assert.match(html, /scheduleList/);
  assert.match(html, /hydrateSlimTools/);
  assert.match(html, /加载对话…/);
  assert.match(html, /await loadEvents\(\"beats\", \{ paint: false \}\)/);
  assert.match(html, /runResync/);
  assert.match(html, /BUNDLE_SHOW/);
  assert.match(html, /hookIsBeat/);
  assert.match(html, /pendingHookMeta/);
  assert.match(html, /clipvault-sessions-pause/);
  assert.match(html, /clipvault-ui-metrics/);
  assert.match(html, /html.embed \.app \{/);
  assert.match(html, /truncated /);
  assert.match(server, /raw_truncated/);
  const indexHtml = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
  assert.match(indexHtml, /clipvault-ui-metrics/);
  assert.match(indexHtml, /clipvault-sessions-settled/);
  assert.match(indexHtml, /emitSessionsLayout/);
  assert.match(indexHtml, /trae_sessions_layout/);
  assert.match(server, /"ts": str\(row.get\("ts"\)/);
  assert.doesNotMatch(html, /loadHealth\(\);\s*loadSessions\(\);\s*ingestHookIds/);
  assert.doesNotMatch(html, /if \(uniq\.length > 16\) \{\s*await loadEvents\(\)/);
  assert.match(taste, /\/api\/events[`']? 列表不含 tool_input/);
  assert.match(agents, /hook 禁止每次拉[^\\n]*\/api\/sessions[^\\n]*全量 events/);
});
