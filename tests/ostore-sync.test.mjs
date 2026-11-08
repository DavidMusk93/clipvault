/**
 * ClipVault ostore 实时同步契约（第二个 wire）。
 *
 * 回归：per-host trx 日志必须能在 ostore 上原样搬运 —— 附件先于 trx、一次 list 做发现、
 * 事件只触发 cycle、游标按 host 不按 wire、备份目录绝不参与同步。
 * Run via scripts/check-frontend.sh — that script does not glob.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const wire = src('OstoreSyncWire.swift');
const sync = src('CloudDocsSyncService.swift');
const web = src('WebServer.swift');
const doc = readFileSync(join(root, 'docs/ostore-sync.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

function slice(text, needle, maxLen = 4000) {
  const start = text.indexOf(needle);
  assert.ok(start >= 0, `missing ${needle}`);
  return text.slice(start, start + maxLen);
}

test('this file is in the deploy frontend gate', () => {
  assert.match(check, /ostore-sync\.test\.mjs/);
});

test('one protocol, three wires: transport is config, not a fork', () => {
  const cfg = slice(sync, 'struct Config: Codable, Equatable', 2400);
  assert.match(cfg, /var transport: String = "clouddocs"/);
  assert.match(cfg, /var ostorePrefix: String = "clipvault\/sync\/v1"/);
  // A sync.json written before ostore existed must still decode.
  assert.match(cfg, /init\(from decoder: Decoder\) throws/);
  assert.match(cfg, /decodeIfPresent\(String\.self, forKey: \.transport\)/);
  assert.match(cfg, /var usesOstore: Bool/);
  assert.match(cfg, /var usesCloudDocs: Bool/);
});

test('the ostore wire keeps the iCloud layout, not a second log format', () => {
  assert.match(wire, /func trxPath\(host: String, seq: Int\) -> String/);
  assert.match(wire, /"\\\(prefix\)\/trx\/\\\(host\)\/\\\(String\(format: "%016d", seq\)\)\.json"/);
  assert.match(wire, /func attachedPath\(key: String\) -> String \{ "\\\(prefix\)\/attach\/\\\(key\)\.bin" \}/);
  assert.match(wire, /func headPath\(host: String\) -> String/);
  // Blob keys carry `.rtf` / `.pdf` suffixes; the path must not sanitize them away.
  assert.match(doc, /attach\/\{key\}\.bin/);
});

test('credentials are the cold-backup file, https only, never in the status payload', () => {
  assert.match(wire, /config\/ostore-backup\.json/);
  assert.match(wire, /parsed\.scheme == "https"/);
  // `enabled` is the backup switch; pausing backup must not silently stop sync.
  assert.match(wire, /The `enabled` flag belongs to the\s*\n?\s*\/\/\/ backup mirror only/);
  assert.doesNotMatch(wire, /token\.isEmpty == false \?/);
  const status = slice(sync, 'private func buildStatus() -> Status', 5000);
  assert.doesNotMatch(status, /ostoreBaseURL|token/i, 'status must not echo the token');
  assert.match(web, /"ostoreBaseHost": st\.ostoreBaseHost as Any/);
});

test('publishing never pays for a listing, and attachments go before the trx that names them', () => {
  const push = slice(sync, 'private func ostorePush() -> StepResult', 6000);
  // A capture must not depend on a recursive listing of a log that only grows.
  assert.doesNotMatch(push, /ostoreIndex\(/);
  // blobs first: `for key in op.blobKeys` runs before `for (op, file) in ops`
  const blobLoop = push.indexOf('for key in op.blobKeys');
  const trxLoop = push.indexOf('for (op, file) in ops');
  assert.ok(blobLoop > 0 && trxLoop > blobLoop, 'attachments must be queued before the trx object');
  // Content-addressed attachments: existence is identity, and the process memoizes.
  assert.match(push, /if \(try\? wire\.exists\(path: path\)\) == true \{/);
  assert.match(push, /publishedAttachments\.insert\(key\)/);
  // Idle cycles refresh the head at most every 30 s, not on every event tick.
  assert.match(push, /if now - lastHeadWriteUnix >= 30 \{/);
  // Outbox ownership: on `both` the iCloud push deletes the op files, alone we do.
  assert.match(push, /if !config\.usesCloudDocs \{/);
});

test('pulling an event means one GET; only startup/reset/poll lists', () => {
  const pull = slice(sync, 'private func ostorePull(reason: String) -> StepResult', 7000);
  assert.match(pull, /let fromEvents = \(reason == "ostore-event" \|\| reason == "ostore-blob"\)/);
  assert.match(pull, /if fromEvents && !ostorePeerRemote\.isEmpty \{/);
  assert.match(pull, /peers = try ostoreIndex\(wire, checksums: false\)\.trxMaxSeq/);
  assert.match(pull, /try wire\.getIfPresent\(path: path\)/);
  // A 404 is "not published yet", not a transport error.
  assert.match(wire, /if status == 404 \{ return nil \}/);
  // Events carry the seq, so the fast path knows how far to pull.
  const handler = slice(sync, 'private func handleOstoreEvent(', 1400);
  assert.match(handler, /ostorePeerRemote\[t\.host\] = max\(ostorePeerRemote\[t\.host\] \?\? 0, t\.seq\)/);
});

test('publishing batches inline JSON and falls back for servers without /api/batch', () => {
  const plan = slice(sync, 'private func publishPlan(', 4000);
  assert.match(plan, /if let reply = try wire\.batch\(items\)/);
  assert.match(plan, /let reply = try wire\.put\(path: item\.path, data: item\.data\)/);
  assert.match(wire, /if status == 404 \|\| status == 405 \{\s*\n\s*lock\.lock\(\); batchUnsupported = true/);
  assert.ok(
    plan.indexOf('case .inline') < plan.indexOf('case .file'),
    'inline objects should flush before a streamed attachment'
  );
  // Server caps are 256 objects / 16 MiB; we stay well under both.
  assert.match(wire, /static let batchMaxObjects = 96/);
  assert.match(wire, /static let batchMaxBytes = 6 \* 1024 \* 1024/);
});

test('object identity is md5 because list.sha256 is unreliable on current ostore builds', () => {
  assert.match(sync, /if let got = reply\.md5, got\.lowercased\(\) != expected/);
  assert.match(sync, /Insecure\.MD5\(\)/);
  assert.match(doc, /认 `md5`/);
});

test('the event stream only triggers a cycle; listing plus cursor stay authoritative', () => {
  const handler = slice(sync, 'private func handleOstoreEvent(', 1200);
  assert.match(handler, /scheduleDrain\(reason: "ostore-event", delay: 0\.15\)/);
  assert.doesNotMatch(handler, /applyOpLocked|applyPulledOp/, 'events must not apply anything themselves');
  assert.match(wire, /\/api\/events\?prefix=/);
  assert.match(wire, /kind == "stream\.reset"/);
  assert.match(wire, /req\.timeoutInterval = 25/);
  assert.match(wire, /if line\.hasPrefix\(":"\) \{ continue \}/);
});

test('pulling uses the same apply path and the same per-host cursor as iCloud', () => {
  const pull = slice(sync, 'private func ostorePull(reason: String) -> StepResult', 6000);
  assert.match(pull, /let outcome = applyPulledOp\(op, host: host, seq: next\)/);
  assert.match(sync, /private func applyPulledOp\(_ op: SyncOp, host: String, seq: Int\)/);
  assert.match(sync, /self\.database\.metaSetSync\(self\.appliedKey\(host: host\), String\(seq\)\)/);
  // Both wires call the shared applier — no duplicated merge rules.
  const cloud = slice(sync, 'private func pullRemote() -> StepResult', 8000);
  assert.match(cloud, /let outcome = applyPulledOp\(op, host: head\.host, seq: next\)/);
  assert.match(pull, /if blobWaits > 0 \{/);
  assert.match(pull, /scheduleDrain\(reason: "ostore-blob", delay: 0\.6\)/);
});

test('realtime budget: fast local drain, event-driven, 2s poll fallback', () => {
  const drain = slice(sync, 'private func scheduleDrain(reason: String, delay: Double? = nil)', 900);
  assert.match(drain, /delay \?\? \(config\.usesOstore \? 0\.15 : 1\.5\)/);
  const poll = slice(sync, 'private func pollInterval() -> Double', 700);
  assert.match(poll, /config\.ostoreOfflinePollSeconds/);
  assert.match(sync, /var ostoreOfflinePollSeconds: Double = 2/);
  assert.match(sync, /var ostoreOnlinePollSeconds: Double = 30/);
  // iCloud keeps its own slower cadence during an event storm.
  assert.match(sync, /let isOstoreDrain = \(reason == "ostore-event" \|\| reason == "ostore-blob"\)/);
  assert.match(sync, /nowUnix - lastCloudCycleUnix >= 5/);
  assert.match(doc, /≤ 3s|3s/);
});

test('the transport can be switched at runtime and reports its state', () => {
  assert.match(sync, /func setTransport\(_ transport: String, prefix: String\? = nil/);
  assert.match(sync, /let allowed: Set<String> = \["clouddocs", "ostore", "both"\]/);
  assert.match(web, /obj\["transport"\] as\? String/);
  for (const field of [
    '"transport": st.transport',
    '"ostorePrefix": st.ostorePrefix as Any',
    '"ostoreConnected": st.ostoreConnected',
    '"ostoreLastEventUnix": st.ostoreLastEventUnix as Any'
  ]) {
    assert.ok(web.includes(field), `sync status missing ${field}`);
  }
  assert.match(sync, /var ostoreConnected: Bool = false/);
});

test('the cold backup is never the sync bus', () => {
  const syncPaths = slice(sync, 'private func ostorePush() -> StepResult', 9000);
  assert.doesNotMatch(syncPaths, /clipvault\/backup|backup\/hosts|OstoreBackup/);
  assert.match(doc, /禁止\*\*把 `clipvault\/backup\/\*\*`（冷备切片）当同步总线/);
  // iCloud wire layout must stay untouched.
  assert.match(sync, /appendingPathComponent\("ClipFlow\/sync\/v1", isDirectory: true\)/);
});

test('lag and delivery are observable without reading note bodies', () => {
  assert.match(sync, /payload: \["n": pushed\.n, "reason": reason, "wire": "ostore"\]/);
  assert.match(sync, /payload: \["n": pulled\.n, "reason": reason, "wire": "ostore"\]/);
  assert.match(sync, /payload: \["kind": kind, "n": stat\.ok, "wire": "ostore"\]/);
  for (const name of ['sync_push', 'sync_pull', 'sync_apply', 'sync_blob_wait', 'sync_queue_depth', 'sync_peer_lag']) {
    assert.ok(doc.includes(name), `docs/ostore-sync.md missing metric ${name}`);
  }
});

test('the stream lock is never held across Task.detached (deadlocks the sync queue)', () => {
  const body = slice(wire, 'func startEvents(', 9000);
  const locks = (body.match(/lock\.lock\(\)/g) || []).length;
  const unlocks = (body.match(/lock\.unlock\(\)/g) || []).length;
  assert.equal(locks, unlocks, 'every lock in startEvents must be released');
  // Task creation must happen outside the critical section.
  const create = body.indexOf('let task = Task.detached');
  const lastLockBefore = body.lastIndexOf('lock.lock()', create);
  const lastUnlockBefore = body.lastIndexOf('lock.unlock()', create);
  assert.ok(lastUnlockBefore > lastLockBefore, 'Task.detached must not be created under the lock');
});

test('a cycle that is already running never swallows the next one', () => {
  const cyc = slice(sync, 'private func cycle(reason: String, completion:', 9000);
  assert.match(cyc, /pendingCycleReason = reason/);
  assert.match(cyc, /if let next = pendingCycleReason \{\s*\n\s*pendingCycleReason = nil\s*\n\s*queue\.async/);
  assert.match(sync, /private var pendingCycleReason: String\?/);
});
