/**
 * ClipVault control-plane SSE contract (nmem pulse SSE architecture).
 * Run via scripts/check-frontend.sh — that script does not glob.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const web = src('WebServer.swift');
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

test('sync capture posts ClipVaultItemAdded with itemId', () => {
  const sync = src('CloudDocsSyncService.swift');
  const slice = sliceFrom(sync, 'if changed {', 600);
  assert.match(slice, /object: capture \? op\.itemId : nil/);
  assert.match(slice, /kind == "upsert"/);
});

test('OCR follow-up upsert is packed into trx after capture', () => {
  const sync = src('CloudDocsSyncService.swift');
  const monitor = src('ClipboardMonitor.swift');
  const db = src('DatabaseManager.swift');
  const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
  assert.match(sync, /func recordLocalOCR/);
  assert.match(sync, /scheduleDrain\(reason: "ocr"\)/);
  assert.match(sync, /op\.note = "ocr"/);
  assert.match(sync, /replayLocalOCRIfNeeded/);
  assert.match(sync, /sync\.ocr_replay_v1/);
  assert.match(monitor, /recordLocalOCR\(/);
  assert.match(monitor, /contentHash: hash/);
  assert.match(db, /func listOCRPayloadsForSyncLocked/);
  assert.match(db, /ocr_text = CASE WHEN \? IS NOT NULL AND length\(\?\) > length\(COALESCE\(ocr_text/);
  assert.match(agents, /OCR 是派生字段/);
  assert.match(agents, /sync\.ocr_replay_v1/);
});

test('unpin JSON nulls pinnedAt and SSE clip_pinned', () => {
  const json = sliceFrom(web, 'dict["pinned"] = true', 400);
  assert.match(json, /pinnedAt"\] = NSNull\(\)/);
  const pin = sliceFrom(web, 'func handleClipPin', 1800);
  assert.match(pin, /broadcastSSE\(event: "clip_pinned"/);
  assert.match(indexHtml, /d\.type === 'clip_pinned'/);
  assert.match(web, /broadcastSSE\(event: "update", id: id\)/);
  assert.match(web, /note\.object as\? ClipboardItem/);
  assert.match(web, /note\.object as\? String/);
  assert.match(web, /headOnly/);
  assert.match(web, /\$0\.name == "fields"/);
  assert.match(web, /headOnly: headOnly/);
});

test('browser edge is one-hop HTTP/2 (h2c :80 / TLS :443)', () => {
  const rust = readFileSync(join(root, 'http-front/src/main.rs'), 'utf8');
  const cargo = readFileSync(join(root, 'http-front/Cargo.toml'), 'utf8');
  const front = src('HttpFrontProcess.swift');
  const origin = src('HTTPByteSink.swift');
  const wire = src('OriginWire.swift');
  const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
  assert.match(cargo, /name = "clipvault-http"/);
  assert.match(rust, /mod origin/);
  assert.match(rust, /tls_enabled/);
  assert.match(rust, /127\.0\.0\.1:80/);
  assert.match(rust, /127\.0\.0\.1:443/);
  assert.match(front, /clipvault-http/);
  assert.match(origin, /OriginUnixServer/);
  assert.match(wire, /CV01/);
  assert.match(web, /HttpFrontProcess/);
  assert.match(web, /OriginWire/);
  assert.match(agents, /clipvault-http/);
  assert.doesNotMatch(rust, /8443/);
  assert.doesNotMatch(rust, /http1::handshake/);
  assert.doesNotMatch(web, /private func sendResponse/);
  assert.doesNotMatch(web, /HTTP\/1\.1 \d{3}/);
  assert.match(rust, /mod metrics/);
  assert.match(rust, /metrics::emit/);
  const metricsRs = readFileSync(join(root, 'http-front/src/metrics.rs'), 'utf8');
  assert.match(metricsRs, /http_req/);
  assert.match(metricsRs, /http-metrics\.jsonl/);
  assert.match(src('UiMetrics.swift'), /drainHttpFront/);
  assert.match(src('UiMetrics.swift'), /"route"/);
  assert.match(agents, /http_req/);
});

test('server SSE: retry, no buffering, heartbeat, bounded resync', () => {
  const attach = sliceFrom(web, 'func attachSSELocked', 4000);
  assert.match(web, /retry: 3000/);
  assert.match(attach, /sseHelloBodyLocked/);
  assert.match(attach, /X-Accel-Buffering/, 'proxy must not buffer the stream');
  assert.match(attach, /text\/event-stream/);
  assert.match(attach, /OriginWire\.encodeResponse/);
  assert.match(attach, /stream: true/);
  assert.doesNotMatch(web, /static func httpChunk/);
  const drop = sliceFrom(web, 'func dropSSELocked', 500);
  assert.match(drop, /connection\.cancel\(\)/, 'SSE drop must close the unix fd');
  const sink = src('HTTPByteSink.swift');
  assert.match(sink, /O_NONBLOCK/);
  assert.match(sink, /MSG_PEEK/);
  assert.match(sink, /EAGAIN/);
  const rust = readFileSync(join(root, 'http-front/src/main.rs'), 'utf8');
  const originrs = readFileSync(join(root, 'http-front/src/origin.rs'), 'utf8');
  assert.match(originrs, /struct OriginBody/);
  assert.match(rust, /keep_alive_interval/);
  assert.match(web, /sseResyncFrame/);
  assert.match(web, /resync_required/);
  assert.match(web, /ssePingFrame/);
  assert.match(web, /ssePingFrameLocked/);
  assert.match(web, /sseHelloBodyLocked/);
  assert.match(web, /tickProcLocked/);
  assert.match(web, /ProcMetrics/);
  assert.match(web, /\/api\/ui-metrics\/proc/);
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
  assert.match(indexHtml, /await mergeNotesHead\(\)/);
  assert.match(indexHtml, /wall_resync/);
  assert.match(indexHtml, /skip_boot/);
  assert.match(indexHtml, /kind: 'connected'/);
  assert.match(indexHtml, /sse_wall/);
  assert.match(indexHtml, /id="debugDrawer"/);
  assert.match(indexHtml, /visibilitychange/);
  assert.match(indexHtml, /pageshow/);
  assert.match(setup, /EventSource\.CLOSED/);
  assert.match(indexHtml, /d\.type === 'ping'/);
  assert.match(indexHtml, /sseDebug\.proc/);
  assert.match(indexHtml, /id="debugProcKv"/);
  assert.match(indexHtml, /resync_required/);
  assert.match(setup, /scheduleResync\(\)/);
  assert.match(indexHtml, /backup_status/);
  assert.match(indexHtml, /ingestClipById/);
  assert.match(indexHtml, /prependCardsIncremental/);
  assert.match(indexHtml, /clipHeadSig/);
  assert.match(indexHtml, /reason: 'sig'/);
  assert.match(indexHtml, /fields: 'head'/);
  assert.match(indexHtml, /function applyFreshItems/);
  assert.match(indexHtml, /scheduleBackupLite/);
  assert.match(indexHtml, /\/api\/backup\/status/);
  assert.match(indexHtml, /\?lite=1/);
  assert.match(indexHtml, /BroadcastChannel\('cv\.sse\.v1'\)/);
  assert.match(indexHtml, /function considerElect/);
  assert.match(indexHtml, /function teardownSSE/);
  assert.match(indexHtml, /trae_ask/);
  assert.match(web, /class TraeAskFanIn/);
  assert.doesNotMatch(indexHtml, /setupTraeAskSSE/);
  assert.doesNotMatch(indexHtml, /EventSource\('\/trae\/api\/stream'\)/);
  assert.doesNotMatch(
    indexHtml,
    /setInterval\(\(\) => \{\s*if \(!document\.getElementById\('backupDrawer'\)/,
    'must not poll backup/status every 30s on the wall',
  );
  assert.doesNotMatch(setup, /fetchPage\(\{\s*reset:\s*true/);
  assert.doesNotMatch(
    setup,
    /es\.close\(\);\s*setTimeout\(setupSSE/,
    'must not close+timer on every onerror (background tabs throttle setTimeout)',
  );
  const vis = sliceFrom(indexHtml, 'function onFeedVisible()', 500);
  assert.match(vis, /considerElect/);
  assert.match(vis, /setupSSE\(\)/);
  assert.match(vis, /scheduleResync\(\)/);
  assert.match(vis, /visibilityState === 'hidden'/);
  const elect = sliceFrom(indexHtml, 'function considerElect()', 1600);
  assert.match(elect, /role = 'bg'/);
  assert.match(elect, /setSseLeader\(true\)/);
  assert.doesNotMatch(
    elect,
    /visibilityState === 'hidden'[\s\S]{0,280}teardownSSE\(\);\s*return;/,
    'solo hidden tab must not drop EventSource immediately',
  );
});

test('swift CI does not cache .build PCH across repo-path renames', () => {
  const ci = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8');
  const cache = sliceFrom(ci, 'name: Cache SPM', 900);
  assert.doesNotMatch(cache, /^\s+\.build\s*$/m);
  assert.match(cache, /org\.swift\.swiftpm/);
  assert.match(cache, /spm-clipvault-/);
  assert.match(ci, /rm -rf \.build/);
});
