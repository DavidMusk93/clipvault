/**
 * Session history must keep the tool timeline. LIMIT 200 newest tools
 * leaves historical turns as Stop conclusions only — same class of bug
 * as CLIENT_CAP on the wall.
 * Run via scripts/check-frontend.sh.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';
import { imMessagesFromEvents, layoutImRows } from '../web/session-render.mjs';

const html = readFileSync(join(root, 'trae_hooks/web/sessions.html'), 'utf8');
const server = readFileSync(join(root, 'trae_hooks/server.py'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

function ev(id, ts, hook, extra = {}) {
  return { event_id: id, ts: String(ts).padStart(4, '0'), hook_event: hook, ...extra };
}

function toolCount(layout) {
  let n = 0;
  for (const item of layout) {
    if (item.type === 'bundle') n += (item.rows || []).length;
    else if (item.type === 'focus' && item.row?.role === 'tool') n += 1;
  }
  return n;
}

test('this file is in the deploy frontend gate', () => {
  assert.match(check, /session-thread\.test\.mjs/);
});

test('AGENTS.md forbids tail-capping the session tool index', () => {
  assert.match(agents, /历史只剩 Stop 结论/);
  assert.match(agents, /工具 stub 全量/);
  assert.match(agents, /禁止 LIMIT 200 砍尾/);
  assert.match(agents, /session-thread\.test\.mjs/);
});

test('server returns the full tool index, not LIMIT 200 DESC', () => {
  assert.match(server, /def index_session_tools/);
  assert.match(server, /tool_index_cols/);
  assert.match(server, /Never tail-cap/);
  const toolsBlock = server.slice(server.indexOf('if view != "beats":'));
  assert.match(toolsBlock, /ORDER BY ts ASC/);
  assert.doesNotMatch(
    toolsBlock.slice(0, 900),
    /ORDER BY ts DESC\s+LIMIT \?/,
    'session tools must not be newest-200',
  );
  assert.doesNotMatch(toolsBlock.slice(0, 900), /tool_input, tool_response/);
});

test('client loads tools without limit=200 and hydrates open slims', () => {
  assert.match(html, /if \(kind !== "tools"\) params\.set\("limit", "200"\)/);
  assert.match(html, /await hydrateSlimTools\(\)/);
  assert.doesNotMatch(html, /ids\.slice\(-1\)/);
  assert.match(html, /const pool = 4/);
});

test('LIMIT 200 newest tools hides historical execution (Stop-only turns)', () => {
  const beats = [];
  const tools = [];
  let t = 1;
  for (let turn = 0; turn < 5; turn++) {
    beats.push(ev(`U${turn}`, t++, 'UserPromptSubmit', { prompt: `q${turn}` }));
    for (let i = 0; i < 80; i++) {
      tools.push(ev(`T${turn}-${i}`, t++, 'PostToolUse', {
        tool_name: 'Read',
        tool_use_id: `u${turn}-${i}`,
      }));
    }
    beats.push(ev(`S${turn}`, t++, 'Stop', { last_assistant_message: `done ${turn}` }));
  }
  beats.push(ev('U5', t++, 'UserPromptSubmit', { prompt: 'latest' }));
  for (let i = 0; i < 50; i++) {
    tools.push(ev(`R${i}`, t++, 'PostToolUse', {
      tool_name: 'Shell',
      tool_use_id: `r${i}`,
    }));
  }
  beats.push(ev('S5', t++, 'Stop', { last_assistant_message: 'final' }));

  const full = layoutImRows(imMessagesFromEvents([...beats, ...tools]));
  const capped = layoutImRows(imMessagesFromEvents([...beats, ...tools.slice(-200)]));

  assert.equal(toolCount(full), 5 * 80 + 50, 'full index keeps every PostToolUse');
  assert.ok(toolCount(capped) < 400, 'newest-200 drops historical tools');

  const fullHasEarlyBundle = full.some((item) => (
    item.type === 'bundle' && item.rows.some((r) => String(r.event.event_id || '').startsWith('T0-'))
  ));
  const cappedHasEarlyBundle = capped.some((item) => (
    item.type === 'bundle' && item.rows.some((r) => String(r.event.event_id || '').startsWith('T0-'))
  ));
  assert.equal(fullHasEarlyBundle, true, 'turn 0 keeps its tool bundle');
  assert.equal(cappedHasEarlyBundle, false, 'turn 0 would be Stop-only under LIMIT 200');

  const earlyStop = capped.filter((item) => item.type === 'focus' && item.row?.event?.event_id === 'S0');
  assert.equal(earlyStop.length, 1);
  assert.equal(earlyStop[0].row.event.last_assistant_message, 'done 0');
});
