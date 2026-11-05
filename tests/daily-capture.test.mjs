import assert from 'node:assert/strict';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { src, root } from './helpers/src.mjs';

const source = src('DatabaseManager.swift');
const sync = src('CloudDocsSyncService.swift');
const helper = source.slice(source.indexOf('private func findIdByHash('), source.indexOf('private func persistTextHash('));
const sql = helper.match(/let sql = """\n([\s\S]*?)\n\s*"""/)[1];
const filter = helper.match(/let dayFilter = captureDate == nil \? "" : """\n([\s\S]*?)\n\s*"""/)[1];
const lookup = (column, daily = true) => sql.replace('\\(column)', column).replace('\\(dayFilter)', daily ? filter : '');
const maintenance = source.slice(source.indexOf('private func dedupeStaleBatch('), source.indexOf('private func pruneOrphanFTS('));
const selectVictims = maintenance.match(/let selectSQL = """\n([\s\S]*?)\n\s*"""/)[1].replace('\\(limit)', '50');

function fixture(t) {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`CREATE TABLE clipboard_items (
    id TEXT PRIMARY KEY, timestamp REAL, content_hash TEXT, text_hash TEXT,
    type TEXT DEFAULT 'text', copy_count INTEGER DEFAULT 1, deleted_at REAL,
    pinned_at REAL, archive_html_sha TEXT, reader_state TEXT);
    CREATE TABLE compose_ops(item_id TEXT);
    CREATE TABLE reader_ops(item_id TEXT);
    CREATE TABLE clip_links(from_item_id TEXT, to_item_id TEXT);
    CREATE TABLE clip_link_ops(from_item_id TEXT, to_item_id TEXT);`);
  const add = (id, timestamp, count = 1, hash = 'body', textHash = 'semantic') => {
    db.prepare('INSERT INTO clipboard_items(id,timestamp,copy_count,content_hash,text_hash) VALUES (?,?,?,?,?)').run(id,timestamp,count,hash,textHash);
  };
  return { db, add };
}

// Tiny epochs are deliberately independent of today's date; the Swift clock test
// separately covers the display zone, midnight, and 23/25-hour DST boundaries.
test('yesterday remains byte-for-byte unchanged when today starts a new counter', t => {
  const { db, add } = fixture(t);
  add('yesterday', 86399.99, 7);
  const original = db.prepare('SELECT * FROM clipboard_items').get();
  for (const column of ['content_hash', 'text_hash']) {
    const hash = column === 'content_hash' ? 'body' : 'semantic';
    assert.equal(db.prepare(lookup(column)).get(hash, 86400, 172800), undefined);
  }
  add('today', 86400, 1);
  const found = db.prepare(lookup('content_hash')).get('body', 86400, 172800);
  assert.equal(found.id, 'today');
  db.prepare('UPDATE clipboard_items SET timestamp=?,copy_count=copy_count+1 WHERE id=?').run(86500, found.id);
  assert.equal(db.prepare('SELECT copy_count FROM clipboard_items WHERE id=?').get('today').copy_count, 2);
  assert.deepEqual(db.prepare('SELECT * FROM clipboard_items WHERE id=?').get('yesterday'), original);
});

test('delayed captures and semantic duplicates match their own day, not the latest day', t => {
  const { db, add } = fixture(t);
  add('older', 100, 4);
  add('today', 86500, 2, 'html-variant');
  assert.equal(db.prepare(lookup('content_hash')).get('body', 0, 86400).id, 'older');
  assert.equal(db.prepare(lookup('text_hash')).get('semantic', 86400, 172800).id, 'today');
  assert.equal(db.prepare(lookup('content_hash')).get('body', 86400, 172800), undefined);
});

test('same-day trash can revive but a note or compose history cannot become a capture', t => {
  const { db, add } = fixture(t);
  add('trash', 86500);
  add('note', 86600);
  add('compose', 86700);
  db.exec("UPDATE clipboard_items SET deleted_at=87000 WHERE id='trash'; UPDATE clipboard_items SET type='note' WHERE id='note'; INSERT INTO compose_ops VALUES ('compose');");
  assert.equal(db.prepare(lookup('content_hash')).get('body', 86400, 172800).id, 'trash');
  assert.equal(db.prepare(lookup('content_hash', false)).get('body').id, 'compose', 'all-day locators keep their existing behavior');
});

test('maintenance preserves every old-day row even if today has the same body', t => {
  const { db, add } = fixture(t);
  add('old-a', 100);
  add('old-b', 200);
  add('today-a', 86500);
  add('today-b', 86600);
  const victims = db.prepare(selectVictims).all(86400, 172800, 86400, 172800).map(x => x.id);
  assert.deepEqual(victims, ['today-a']);
});

test('old pinned cards and same-day trash cannot erase a current capture', t => {
  const { db, add } = fixture(t);
  add('old-pin', 100);
  add('today', 86500);
  add('trash', 86600);
  db.exec("UPDATE clipboard_items SET pinned_at=200 WHERE id='old-pin'; UPDATE clipboard_items SET deleted_at=87000 WHERE id='trash';");
  assert.deepEqual(db.prepare(selectVictims).all(86400, 172800, 86400, 172800), []);
});

test('local and remote capture paths pass the capture date to both hash lookups', () => {
  const local = source.slice(source.indexOf('func saveItemDetailed('), source.indexOf('// MARK: - Multi-device sync helpers'));
  assert.match(local, /findIdByContentHash\(item.contentHash, captureDate: item.timestamp\)/);
  assert.match(local, /findIdByTextHash\(th, captureDate: item.timestamp\)/);
  const remote = source.slice(source.indexOf('func applySyncUpsertLocked('), source.indexOf('func applySyncTombstoneLocked('));
  assert.match(remote, /findIdByContentHash\(contentHash, captureDate: timestamp\)/);
  assert.match(remote, /findIdByTextHash\(th, captureDate: timestamp\)/);
  assert.ok(remote.indexOf('captureTimestampLocked') < remote.indexOf('findIdByContentHash'), 'derived upserts must resolve their original id before hash aliases');
  assert.match(remote, /isSameCaptureDay/);
  assert.match(remote, /daily-capture:/, 'legacy cross-day touches fork deterministic identities');
  assert.match(remote, /copyCount = 1/);
  assert.doesNotMatch(remote, /bumpLatestAlive/, 'sync replay merges absolute counters without incrementing twice');
  assert.match(sync, /op.copyCount = dailyCount/);
  assert.match(sync, /captureCopyCountLocked\(id: itemId\)/);
});

test('daily capture regression is registered in the deployment gate', () => {
  assert.match(readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8'), /daily-capture\.test\.mjs/);
});
