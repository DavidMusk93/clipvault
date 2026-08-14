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
