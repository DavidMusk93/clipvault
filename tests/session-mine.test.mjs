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
  assert.match(html, /cv-mine-float/);
  assert.match(html, /bottom:\s*52px/);
  assert.match(html, /data-scope="session"/);
  assert.match(html, /data-scope="recent"/);
  assert.match(html, /复制反馈到剪贴板/);
  assert.match(html, /cv\.trae\.mine\.v1/);
  assert.match(html, /sessMetricsCtl\?\.setOpen/);
});

test('directions cover user and agent axes', () => {
  for (const id of ['user.cwd', 'user.git', 'user.taste', 'agent.files', 'agent.tools', 'agent.mcp', 'agent.phases']) {
    assert.match(mine, new RegExp(`"id": "${id}"`));
  }
});
