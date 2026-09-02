/**
 * ClipVault control-plane SSE contract (nmem pulse SSE architecture).
 * Run via scripts/check-frontend.sh — that script does not glob.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const web = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');
const indexHtml = readFileSync(join(root, 'web/index.html'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

function sliceFrom(src, startNeedle, maxLen = 12000) {
  const start = src.indexOf(startNeedle);
  assert.ok(start >= 0, `missing ${startNeedle}`);
  return src.slice(start, start + maxLen);
}

test('this file is in the deploy frontend gate', () => {
  assert.match(check, /sse-control\.test\.mjs/);
});

test('server SSE: retry, no buffering, heartbeat, bounded resync', () => {
  const attach = sliceFrom(web, 'func attachSSELocked', 4000);
  assert.match(attach, /retry: 3000/);
  assert.match(attach, /X-Accel-Buffering/, 'proxy must not buffer the stream');
  assert.match(attach, /text\/event-stream/);
  assert.match(web, /sseResyncFrame/);
  assert.match(web, /resync_required/);
  assert.match(web, /ssePingFrame/);
  assert.match(web, /: ping/);
  assert.match(web, /sseMaxBuffered = 32/);
  assert.match(web, /sseHeartbeatSeconds: Int = 15/);
  const enqueue = sliceFrom(web, 'func enqueueSSELocked', 1200);
  assert.match(enqueue, /resyncRequired \{ return \}/);
  assert.match(enqueue, /sseMaxBuffered/);
  assert.match(enqueue, /sseResyncFrame/);
  assert.doesNotMatch(enqueue, /sseSessions\.removeValue/, 'overflow must not drop the client');
});

test('frontend SSE: native retry, coalesced mergeHead, visibility resync', () => {
  const start = indexHtml.indexOf('function setupSSE()');
  const end = indexHtml.indexOf('function onFeedVisible()');
  assert.ok(start >= 0 && end > start, 'setupSSE before onFeedVisible');
  const setup = indexHtml.slice(start, end);
  assert.match(indexHtml, /function scheduleResync/);
  assert.match(indexHtml, /visibilitychange/);
  assert.match(indexHtml, /pageshow/);
  assert.match(setup, /EventSource\.CLOSED/);
  assert.match(setup, /d\.type === 'ping'/);
  assert.match(setup, /resync_required/);
  assert.match(setup, /scheduleResync\(\)/);
  assert.doesNotMatch(setup, /fetchPage\(\{\s*reset:\s*true/);
  assert.doesNotMatch(
    setup,
    /es\.close\(\);\s*setTimeout\(setupSSE/,
    'must not close+timer on every onerror (background tabs throttle setTimeout)',
  );
  const vis = sliceFrom(indexHtml, 'function onFeedVisible()', 400);
  assert.match(vis, /setupSSE\(\)/);
  assert.match(vis, /scheduleResync\(\)/);
});
