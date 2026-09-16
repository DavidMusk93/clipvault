/**
 * Behavioral gate for the metrics summary SQL extracted from UiMetrics.swift.
 * Exercises the window-function percentiles and the http_req route/status split
 * against an in-memory SQLite database (node:sqlite).
 *
 * Run: node --test tests/metrics-sql.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

let DatabaseSync = null;
try {
  ({ DatabaseSync } = await import('node:sqlite'));
} catch (_) {
  DatabaseSync = null;
}
const skip = DatabaseSync ? false : 'node:sqlite unavailable on this runtime';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(
  path.join(__dirname, '../Sources/ClipVault/Metrics/UiMetrics.swift'),
  'utf8',
);

/** Extract `let sql = """..."""` from a Swift function. */
function fnSql(name) {
  const at = src.indexOf(`func ${name}`);
  assert.ok(at >= 0, `${name} not found`);
  const m = src.slice(at).match(/let sql = """([\s\S]*?)"""/);
  assert.ok(m, `${name} sql literal not found`);
  return m[1];
}

const percentileSql = fnSql('percentileLocked').replaceAll('\\(column)', 'dur_ms');
const routesSql = fnSql('httpRoutesLocked');
const rollupSql = fnSql('rollupLocked');
const mergeSql = fnSql('mergeRollupLocked');

function makeDb() {
  const db = new DatabaseSync(':memory:');
  db.exec(
    'CREATE TABLE ui_events (id INTEGER PRIMARY KEY, ts INTEGER, name TEXT, dur_ms REAL, value REAL, ok INTEGER, payload TEXT)',
  );
  const ins = db.prepare('INSERT INTO ui_events (ts, name, dur_ms, value, ok, payload) VALUES (?,?,?,?,?,?)');
  // name 'a': dur 1..100 → p50=50, p95=95, p99=99
  for (let i = 1; i <= 100; i++) ins.run(1000, 'a', i, null, 1, null);
  // name 'b': four values → p50=2, p95=4, p99=4
  [1, 2, 3, 4].forEach((v) => ins.run(1000, 'b', v, null, 1, null));
  // a null-dur row must be ignored by the percentile pass
  ins.run(1000, 'a', null, null, 1, null);
  // http_req rows for the route split
  const payload = (route, status) => JSON.stringify({ kind: 'get', route, n: status });
  ins.run(1000, 'http_req', 10, null, 1, payload('/api/clips', 200));
  ins.run(1000, 'http_req', 20, null, 1, payload('/api/clips', 200));
  ins.run(1000, 'http_req', 500, null, 0, payload('/api/clips', 500));
  ins.run(1000, 'http_req', 5, null, 1, payload('/api/image', 200));
  return db;
}

test('percentile SQL returns exact p50/p95/p99 per name', { skip }, () => {
  const db = makeDb();
  const rows = db.prepare(percentileSql).all(0, 9999);
  // SELECT name, p50, p95, p99 — read the anonymous percentile expressions by position.
  const byName = Object.fromEntries(
    rows.map((r) => [r.name, Object.values(r).slice(1)]),
  );
  assert.deepEqual(byName.a, [50, 95, 99]);
  // 4 values → CAST(4*0.95)=3 → [2,3,3]
  assert.deepEqual(byName.b, [2, 3, 3]);
  db.close();
});

function makeRollupDb() {
  const db = new DatabaseSync(':memory:');
  db.exec(
    'CREATE TABLE ui_events (id INTEGER PRIMARY KEY, ts INTEGER, name TEXT, dur_ms REAL, value REAL, ok INTEGER, over INTEGER, payload TEXT)',
  );
  db.exec(`CREATE TABLE ui_rollup (
    hour INTEGER NOT NULL, name TEXT NOT NULL, n INTEGER NOT NULL,
    ok_n INTEGER NOT NULL, ok_yes INTEGER NOT NULL, over_n INTEGER NOT NULL,
    sum_dur REAL, min_dur REAL, max_dur REAL, dur_n INTEGER NOT NULL DEFAULT 0,
    sum_value REAL, min_value REAL, max_value REAL, value_n INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (hour, name))`);
  const ins = db.prepare('INSERT INTO ui_events (ts, name, dur_ms, value, ok, over) VALUES (?,?,?,?,?,?)');
  // hour 0: two clips rows; second has a null dur but a value
  ins.run(100, 'wall_fetch', 10, null, 1, 0);
  ins.run(200, 'wall_fetch', 30, null, 1, 1);
  ins.run(300, 'wall_fetch', null, 0.4, 0, 0);
  // hour 1: one route row that must stay put
  ins.run(3600100, 'http_req', 5, null, 1, 0);
  return db;
}

test('rollup SQL folds one hour into ui_rollup', { skip }, () => {
  const db = makeRollupDb();
  db.prepare(rollupSql).run(0, 3_600_000);
  const row = db.prepare("SELECT * FROM ui_rollup WHERE hour=0 AND name='wall_fetch'").get();
  assert.equal(row.n, 3);
  assert.equal(row.ok_n, 3);
  assert.equal(row.ok_yes, 2);
  assert.equal(row.over_n, 1);
  assert.equal(row.sum_dur, 40);
  assert.equal(row.dur_n, 2);
  assert.equal(row.min_dur, 10);
  assert.equal(row.max_dur, 30);
  assert.equal(row.value_n, 1);
  assert.ok(Math.abs(row.sum_value - 0.4) < 1e-9);
  assert.equal(db.prepare('SELECT COUNT(*) AS c FROM ui_rollup').get().c, 1, 'only the folded hour');
  db.close();
});

test('merge SQL sums rollup rows back into one aggregate', { skip }, () => {
  const db = makeRollupDb();
  db.prepare(rollupSql).run(0, 3_600_000);
  const rows = db.prepare(mergeSql).all(0, 10);
  const wf = rows.find((r) => r.name === 'wall_fetch');
  assert.equal(wf['SUM(n)'], 3);
  assert.equal(wf['SUM(ok_yes)'], 2);
  assert.equal(wf['SUM(dur_n)'], 2);
  assert.equal(wf['MIN(min_dur)'], 10);
  assert.equal(wf['MAX(max_dur)'], 30);
  db.close();
});

test('http route SQL groups by route+status with error count', { skip }, () => {
  const db = makeDb();
  const rows = db.prepare(routesSql).all(0, 9999);
  const clips200 = rows.find((r) => r.route === '/api/clips' && String(r.status) === '200');
  const clips500 = rows.find((r) => r.route === '/api/clips' && String(r.status) === '500');
  assert.ok(clips200, 'route/status row missing');
  assert.equal(clips200.n, 2);
  assert.equal(clips200.errs, 0);
  assert.equal(clips500.n, 1);
  assert.equal(clips500.errs, 1);
  db.close();
});
