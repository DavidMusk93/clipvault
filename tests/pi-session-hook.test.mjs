/**
 * pi -> ClipVault session hook adapter contract.
 * The adapter is a pi extension (TS) that pipes events through the Trae wrapper.
 * Run via scripts/check-frontend.sh (node --test tests/*.test.mjs).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const adapter = readFileSync(join(root, 'trae_hooks/pi/clipvault-session.ts'), 'utf8');
const install = readFileSync(join(root, 'trae_hooks/pi/install_pi_hook.sh'), 'utf8');
const mine = readFileSync(join(root, 'trae_hooks/mine.py'), 'utf8');
const docs = readFileSync(join(root, 'docs/trae-hooks.md'), 'utf8');

test('pi adapter maps lifecycle to the ClipVault hook contract', () => {
  for (const ev of ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'Notification']) {
    assert.match(adapter, new RegExp(`"${ev}"`), `missing ${ev}`);
  }
  assert.match(adapter, /pi\.on\("session_start"/);
  assert.match(adapter, /pi\.on\("before_agent_start"/);
  assert.match(adapter, /pi\.on\("tool_execution_start"/);
  assert.match(adapter, /pi\.on\("tool_result"/);
  assert.match(adapter, /pi\.on\("agent_settled"/);
  assert.match(adapter, /pi\.on\("ui_prompt_start"/);
});

test('pi adapter normalises tool names for mine.py', () => {
  assert.match(adapter, /return "RunCommand"/);
  assert.match(adapter, /mcp__nowledge-mem__/);
  assert.match(adapter, /return "Read"/);
  assert.match(adapter, /return "Write"/);
  assert.match(adapter, /return "Edit"/);
  assert.match(adapter, /file_path/);
  assert.match(adapter, /wall_time_seconds/);
  assert.match(adapter, /exit_code/);
  assert.match(adapter, /event\.isError \? 1 : 0/);
  assert.match(mine, /def mcp_parts/);
});

test('pi adapter does not block pi and is opt-out', () => {
  assert.match(adapter, /unref\(\)/);
  assert.match(adapter, /CLIPVAULT_PI_SESSION_HOOK !== "0"/);
  assert.match(adapter, /event\.source === "extension"/);
  assert.match(adapter, /CLIPVAULT_HOOK_ENV/);
  assert.match(adapter, /last_assistant_message/);
});

test('install writes the pi env override and links the extension', () => {
  assert.match(install, /pi-hooks\.env/);
  assert.match(install, /CLIPVAULT_INSTANCE_ID="\$\{CLIPVAULT_PI_INSTANCE:-pi-mac\}"/);
  assert.match(install, /CLIPVAULT_HOOK_SOURCE="pi"/);
  assert.match(install, /ln -sfn "\$SRC" "\$PI_EXT"/);
  assert.match(docs, /pi 会话/);
});
