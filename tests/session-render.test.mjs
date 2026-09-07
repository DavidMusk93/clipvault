/**
 * Trae session renderer: JSON / Markdown classification + event blocks.
 * Run: node --test tests/session-render.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  asObj,
  prettyJson,
  toolCommand,
  blocksFromEvent,
  renderValue,
  roleFromEvent,
  imMessagesFromEvents,
  parseHookTs,
  relLocalTime,
  bundleTitle,
  focusImRows,
} from '../web/session-render.mjs';

test('toolCommand prefers cmd then command', () => {
  assert.equal(toolCommand('{"cmd":"rg foo","command":"ignored"}'), 'rg foo');
  assert.equal(toolCommand({ command: 'echo hi' }), 'echo hi');
});

test('prettyJson formats objects and JSON strings', () => {
  assert.match(prettyJson('{"a":1}'), /"a": 1/);
  assert.match(prettyJson({ a: 1 }), /"a": 1/);
});

test('asObj parses JSON strings only', () => {
  assert.deepEqual(asObj('{"x":true}'), { x: true });
  assert.equal(asObj('not-json'), null);
});

test('PostToolUse blocks keep command + output + leftover json', () => {
  const blocks = blocksFromEvent({
    hook_event: 'PostToolUse',
    tool_name: 'RunCommand',
    tool_input: { cmd: 'rg foo', cwd: '/tmp' },
    tool_response: {
      exit_code: 0,
      status: 'Exited',
      wall_time_seconds: 1.2,
      output: 'hit\n',
      chunk_id: 'ws_1',
    },
  });
  const keys = blocks.map((b) => b.key);
  assert.deepEqual(keys, ['command', 'result', 'output', 'tool_response']);
  assert.equal(blocks[0].text, 'rg foo');
  assert.match(blocks[1].text, /exit 0/);
  assert.equal(blocks[2].text, 'hit\n');
  assert.match(blocks[3].text, /chunk_id/);
});

test('UserPromptSubmit is markdown-hinted', () => {
  const blocks = blocksFromEvent({
    hook_event: 'UserPromptSubmit',
    prompt: '# Title\n\n- item\n',
  });
  assert.equal(blocks[0].hint, 'markdown');
});

test('renderValue json hint highlights or escapes', () => {
  const r = renderValue('{"a":1}', 'json', {});
  assert.equal(r.kind, 'json');
  assert.match(r.html, /<pre/);
  assert.match(r.html, /&quot;a&quot;|&quot;a&quot;|"a"/);
});

test('renderValue markdown without libs falls back to escaped pre', () => {
  const r = renderValue('# Hi\n\n- a\n', 'markdown', {});
  assert.equal(r.kind, 'plain');
  assert.match(r.html, /<pre>/);
  assert.doesNotMatch(r.html, /<h1>/);
});

test('IM roles: user / assistant / tool / system', () => {
  assert.equal(roleFromEvent({ hook_event: 'UserPromptSubmit' }), 'user');
  assert.equal(roleFromEvent({ hook_event: 'Stop' }), 'assistant');
  assert.equal(roleFromEvent({ hook_event: 'PostToolUse' }), 'tool');
  assert.equal(roleFromEvent({ hook_event: 'SessionStart' }), 'system');
});

test('IM overview drops PreToolUse when Post exists', () => {
  const rows = imMessagesFromEvents([
    { hook_event: 'PostToolUse', tool_use_id: 'c1', ts: '2', event_id: 'b' },
    { hook_event: 'UserPromptSubmit', ts: '1', event_id: 'a' },
    { hook_event: 'PreToolUse', tool_use_id: 'c1', ts: '1.5', event_id: 'p' },
    { hook_event: 'PreToolUse', tool_use_id: 'orphan', ts: '1.6', event_id: 'o' },
  ]);
  assert.deepEqual(
    rows.map((r) => r.event.hook_event),
    ['UserPromptSubmit', 'PreToolUse', 'PostToolUse'],
  );
  assert.equal(rows[0].role, 'user');
  assert.equal(rows[2].align, 'start');
});

test('naive hook timestamps are UTC, not local wall clock', () => {
  const d = parseHookTs('2026-09-07 04:49:23');
  assert.equal(d.toISOString(), '2026-09-07T04:49:23.000Z');
  assert.equal(relLocalTime('2026-09-07 04:49:23', Date.parse('2026-09-07T04:50:00Z')), '刚刚');
});

test('focus keeps last user, last assistant, latest; merges the tool slog', () => {
  const rows = imMessagesFromEvents([
    { hook_event: 'UserPromptSubmit', ts: '1', event_id: 'u1', prompt: 'old' },
    { hook_event: 'PostToolUse', ts: '2', event_id: 't1', tool_name: 'Read', tool_use_id: 'a' },
    { hook_event: 'Stop', ts: '3', event_id: 's1', last_assistant_message: 'done old' },
    { hook_event: 'UserPromptSubmit', ts: '4', event_id: 'u2', prompt: 'new' },
    { hook_event: 'PostToolUse', ts: '5', event_id: 't2', tool_name: 'RunCommand', tool_use_id: 'b' },
    { hook_event: 'PostToolUse', ts: '6', event_id: 't3', tool_name: 'RunCommand', tool_use_id: 'c' },
    { hook_event: 'Stop', ts: '7', event_id: 's2', last_assistant_message: 'done new' },
    { hook_event: 'PostToolUse', ts: '8', event_id: 't4', tool_name: 'RunCommand', tool_use_id: 'd' },
  ]);
  const focus = focusImRows(rows);
  assert.deepEqual(focus.map((x) => x.type), ['bundle', 'focus', 'bundle', 'focus', 'focus']);
  assert.equal(focus[1].row.event.prompt, 'new');
  assert.equal(focus[3].row.event.last_assistant_message, 'done new');
  assert.equal(focus[4].row.event.event_id, 't4');
  assert.match(bundleTitle(focus[0].rows), /更早 1 轮/);
  assert.match(bundleTitle(focus[2].rows), /2 次工具/);
});

test('IM overview hides SessionStart cwd pills', () => {
  const rows = imMessagesFromEvents([
    { hook_event: 'SessionStart', ts: '1', cwd: '/root/Documents/flowkit', event_id: 's' },
    { hook_event: 'UserPromptSubmit', ts: '1', prompt: 'hi', event_id: 'u' },
    { hook_event: 'Notification', ts: '2', event_id: 'n' },
  ]);
  assert.deepEqual(rows.map((r) => r.event.hook_event), ['UserPromptSubmit']);
});
