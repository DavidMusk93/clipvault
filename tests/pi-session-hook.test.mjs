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
const remoteInstall = readFileSync(join(root, 'trae_hooks/pi/install_pi_hook_remote.sh'), 'utf8');
const installRemote = readFileSync(join(root, 'trae_hooks/install_remote.sh'), 'utf8');
const hookClient = readFileSync(join(root, 'trae_hooks/hook_client.py'), 'utf8');
const spoolFlush = readFileSync(join(root, 'trae_hooks/spool_flush.py'), 'utf8');

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
  assert.match(install, /\. "\$HOOKS_ENV\/trae-hooks\.env"/);
  assert.match(install, /export CLIPVAULT_HOOK_SOURCE="pi"/);
  // instance_id stays the Trae env's (mac-work); source=pi is the differentiator.
  assert.doesNotMatch(install, /CLIPVAULT_INSTANCE_ID/);
  assert.match(install, /ln -sfn "\$SRC" "\$PI_EXT"/);
  assert.match(docs, /pi 会话/);
  assert.match(docs, /source=pi/);
});

test('remote installer deploys the pi adapter over ssh', () => {
  assert.match(remoteInstall, /CLIPVAULT_REMOTE_SSH/);
  assert.match(remoteInstall, /pi-hooks\.env/);
  assert.match(remoteInstall, /\. "\$HOOKS_ENV\/trae-hooks\.env"/);
  assert.match(remoteInstall, /export CLIPVAULT_HOOK_SOURCE="pi"/);
  // instance_id stays the host's Trae env; source=pi is the differentiator.
  assert.doesNotMatch(remoteInstall, /CLIPVAULT_INSTANCE_ID/);
  assert.match(remoteInstall, /scp .*clipvault-session\.ts/);
  // refuses to run until the shared Trae collector exists on the host
  assert.match(remoteInstall, /trae-hooks\.env missing/);
});

test('a fresh collector install also wires pi capture', () => {
  assert.match(installRemote, /install_pi_hook_remote\.sh/);
  assert.match(docs, /install_pi_hook_remote\.sh/);
});

test('spool flush batches multi-row INSERTs with per-row fallback', () => {
  // per-row Quack round trips are ~0.26s; one multi-row INSERT is ~0.002s/row.
  assert.match(hookClient, /def build_insert_many_sql/);
  assert.match(hookClient, /def quack_insert_many/);
  assert.match(hookClient, /ON CONFLICT \(event_id\) DO NOTHING/);
  assert.match(spoolFlush, /quack_insert_many/);
  assert.match(spoolFlush, /BATCH_ROWS/);
  // a failed batch falls back per-row so one bad line never drops the batch
  assert.match(spoolFlush, /quack_insert\(row/);
});
