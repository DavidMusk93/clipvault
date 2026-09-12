/**
 * Session mining is the product. Dumping the transcript is not.
 * Run via scripts/check-frontend.sh.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'trae_hooks/web/sessions.html'), 'utf8');
const server = readFileSync(join(root, 'trae_hooks/server.py'), 'utf8');
const mine = readFileSync(join(root, 'trae_hooks/mine.py'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

test('this file and session_mine_main.py are in the deploy gate', () => {
  assert.match(check, /session-mine\.test\.mjs/);
  assert.match(check, /session_mine_main\.py/);
});

test('AGENTS.md treats sessions as an asset that must be mined', () => {
  assert.match(agents, /会话是资产/);
  assert.match(agents, /\/api\/mine/);
  assert.match(agents, /分析.*调试/);
});

test('server exposes /api/mine without tool bodies', () => {
  assert.match(server, /path == "\/api\/mine"/);
  assert.match(server, /mine_session/);
  assert.match(mine, /substr\(coalesce\(tool_input/);
  assert.match(mine, /substr\(coalesce\(tool_response/);
  assert.doesNotMatch(mine, /SELECT \* FROM hook_events/);
});

test('analysis fab sits above the debug fab', () => {
  assert.match(html, /id="mineOpen"/);
  assert.match(html, />分析<\/button>/);
  assert.match(html, /cv-corner-stack/);
  assert.match(html, /insertBefore\(mineHost, corner\.firstChild\)/);
  assert.match(html, /cv-corner-stack \.cv-metrics-float/);
  assert.doesNotMatch(html, /\.cv-metrics-float \{ bottom: 64px/);
  assert.doesNotMatch(html, /\.cv-mine-float \{[\s\S]{0,80}bottom:\s*52px/);
  assert.match(html, /data-scope="session"/);
  assert.match(html, /data-scope="recent"/);
  assert.match(html, /复制 AGENTS 草稿/);
  assert.match(html, /cv\.trae\.mine\.v1/);
  assert.match(html, /sessMetricsCtl\?\.setOpen/);
});

test('analysis is a stage sheet, not a 420px pop with ellipsis', () => {
  assert.match(html, /cv-mine-sheet/);
  assert.match(html, /inset:\s*8px 8px 52px 8px/);
  const sheet = html.slice(html.indexOf('.cv-mine-sheet'), html.indexOf('.cv-mine-fab.is-on'));
  assert.match(sheet, /overflow-wrap:\s*anywhere/);
  assert.doesNotMatch(sheet, /width:\s*min\(420px/);
  assert.doesNotMatch(sheet, /text-overflow:\s*ellipsis/);
  assert.match(html, /f\.draft/);
  assert.match(html, /f\.evidence/);
  assert.match(html, /b\.tables/);
});

test('directions cover user and agent axes', () => {
  for (const id of ['user.cwd', 'user.git', 'user.taste', 'agent.files', 'agent.tools', 'agent.mcp', 'agent.phases']) {
    assert.match(mine, new RegExp(`"id": "${id}"`));
  }
});

test('taste keys keep skill and project names, not bare SKILL.md', () => {
  assert.match(mine, /def taste_keys/);
  assert.match(mine, /skill:/);
  assert.match(mine, /禁止只记 SKILL\.md 文件名/);
});
