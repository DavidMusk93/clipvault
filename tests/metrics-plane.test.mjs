/**
 * Metrics plane: cost / cache / tok-per-second / context composition.
 * It is a separate plane from hook_events (content) and is fed by two writers
 * that must agree on the join key. Run via scripts/check-frontend.sh.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const schema = readFileSync(join(root, 'trae_hooks/schema.sql'), 'utf8');
const metrics = readFileSync(join(root, 'trae_hooks/metrics.py'), 'utf8');
const ingest = readFileSync(join(root, 'trae_hooks/pi_session_ingest.py'), 'utf8');
const hookClient = readFileSync(join(root, 'trae_hooks/hook_client.py'), 'utf8');
const extension = readFileSync(join(root, 'trae_hooks/pi/clipvault-session.ts'), 'utf8');
const mine = readFileSync(join(root, 'trae_hooks/mine.py'), 'utf8');
const html = readFileSync(join(root, 'trae_hooks/web/sessions.html'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

test('this file and session_metrics_main.py are in the deploy gate', () => {
  assert.match(check, /metrics-plane\.test\.mjs/);
  assert.match(check, /session_metrics_main\.py/);
});

test('schema defines the metrics plane without touching hook_events', () => {
  assert.match(schema, /CREATE TABLE IF NOT EXISTS llm_usage/);
  assert.match(schema, /CREATE TABLE IF NOT EXISTS turn_context/);
  // idempotent migration so an existing store picks up the new column
  assert.match(schema, /ALTER TABLE turn_context ADD COLUMN IF NOT EXISTS skill_loaded_tokens/);
  for (const col of ['ttft_ms', 'tok_s_decode', 'cache_read_tokens', 'cost_total', 'cache_write_tokens']) {
    assert.match(schema, new RegExp(col));
  }
  // hook_events stays content-only
  assert.doesNotMatch(schema.slice(0, schema.indexOf('llm_usage')), /cost_total/);
});

test('both writers key on <session>:<message.timestamp>', () => {
  assert.match(metrics, /f"\{session_id\}:\{message_id\}"/);
  assert.match(ingest, /"entry_id": str\(msg_ms\)/);
  // message.timestamp is the request start; entry.timestamp is completion
  assert.match(ingest, /message\.timestamp = request start; entry\.timestamp = completion/);
  assert.match(ingest, /entry_ts\.replace\(tzinfo=timezone\.utc\)/);
});

test('cold path upserts and preserves the hot-path ttft fields', () => {
  assert.match(metrics, /def upsert_sql/);
  assert.match(metrics, /COALESCE\(excluded\.\{col\}, \{table\}\.\{col\}\)/);
  assert.match(ingest, /USAGE_LIVE_COLS = \("ttft_ms", "decode_ms", "tok_s_decode"\)/);
  assert.match(ingest, /preserve=USAGE_LIVE_COLS/);
});

test('hook_client routes metric events away from hook_events', () => {
  assert.match(metrics, /METRIC_EVENTS = \("UsageReport", "ContextReport"\)/);
  assert.match(hookClient, /if hook_event in METRIC_EVENTS:/);
  assert.match(hookClient, /def emit_metric/);
  // metrics must not be spooled as hook_events rows
  const emit = hookClient.slice(hookClient.indexOf('def emit_metric'), hookClient.indexOf('def main'));
  assert.doesNotMatch(emit, /append_spool/);
});

test('pi extension emits UsageReport with ttft for assistant turns', () => {
  assert.match(extension, /emit\("UsageReport"/);
  assert.match(extension, /ttft_ms:/);
  assert.match(extension, /elapsed_ms:/);
  assert.match(extension, /typeof msg\.timestamp === "number"/);
  // resume/fork must continue the assistant index, not restart at 0
  assert.match(extension, /role === "assistant"\)\.length - 1/);
});

test('skill context cost is measured from the read payload, not the path', () => {
  assert.match(ingest, /def skill_from_call/);
  assert.match(ingest, /_READ_CALL_TOOLS/);
  assert.match(ingest, /_RE_READ_CMD/);
  // a write/edit ack must never be billed as skill context
  assert.match(ingest, /elif tool in _SHELL_CALL_TOOLS:/);
});

test('mine exposes the metrics direction and derives cost/cache/tok-per-second', () => {
  assert.match(mine, /"id": "agent\.metrics"/);
  assert.match(mine, /def metrics_analysis/);
  assert.match(mine, /cacheRead \/ \(cacheRead \+ 未缓存 input\)/);
  assert.match(mine, /def fetch_metrics/);
  assert.match(mine, /FROM llm_usage/);
  assert.match(mine, /FROM turn_context/);
  // missing tables must degrade to empty, not 500
  assert.match(mine, /store may predate the metrics plane/);
});

test('sessions UI surfaces cost and cache hit', () => {
  assert.match(html, /\["费用 USD", s\.cost_usd/);
  assert.match(html, /\["缓存命中%", s\.cache_hit_pct/);
  assert.match(html, /s\.cost_usd, s\.cache_hit_pct, s\.usage_turns/);
});
