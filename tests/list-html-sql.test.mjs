/**
 * Behavioral gate for the list HTML cap + explicit `htmlOmitted` flag.
 *
 * The wall's "list stays light" contract lives in two CASE expressions in
 * DatabaseManager.swift. Rather than grepping for the constants, extract the
 * real SQL and run it against an in-memory SQLite database (node:sqlite).
 *
 * Run: node --test tests/list-html-sql.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dbSrc = fs.readFileSync(
  path.join(__dirname, '../Sources/ClipVault/Store/DatabaseManager.swift'),
  'utf8',
);

function constant(name) {
  const m = dbSrc.match(new RegExp(`${name} = (\\d+)`));
  assert.ok(m, `${name} not found in DatabaseManager.swift`);
  return Number(m[1]);
}

/** Pull a Swift multiline string literal: `name = """ ... """`. */
function sqlLiteral(name) {
  const m = dbSrc.match(new RegExp(`${name} = """([\\s\\S]*?)"""`));
  assert.ok(m, `${name} not found in DatabaseManager.swift`);
  return m[1].trim();
}

const richLimit = constant('listHtmlLimitRich');
const otherLimit = constant('listHtmlLimitOther');

function interpolate(swiftSql) {
  return swiftSql
    .replaceAll('\\(listHtmlLimitRich)', String(richLimit))
    .replaceAll('\\(listHtmlLimitOther)', String(otherLimit));
}

const listSql = interpolate(sqlLiteral('listHtmlSQL'));
const listOmittedSql = interpolate(sqlLiteral('listHtmlOmittedSQL'));
const listSqlAliased = interpolate(sqlLiteral('listHtmlSQLAliased'));
const listOmittedSqlAliased = interpolate(sqlLiteral('listHtmlOmittedSQLAliased'));

function makeDb() {
  const db = new DatabaseSync(':memory:');
  db.exec(
    'CREATE TABLE clipboard_items (id INTEGER PRIMARY KEY, type TEXT, html_content TEXT, html_bytes INTEGER)',
  );
  const ins = db.prepare(
    'INSERT INTO clipboard_items (id, type, html_content, html_bytes) VALUES (?, ?, ?, ?)',
  );
  ins.run(1, 'html', 'x'.repeat(100), 100);                    // small html → ships
  ins.run(2, 'html', 'x'.repeat(richLimit + 100), richLimit + 100); // over rich cap
  ins.run(3, 'html', 'x'.repeat(richLimit - 100), richLimit - 100); // under rich cap
  ins.run(4, 'text', 'x'.repeat(otherLimit + 100), otherLimit + 100); // over other cap
  ins.run(5, 'text', 'x'.repeat(otherLimit - 100), otherLimit - 100); // under other cap
  ins.run(6, 'html', null, null);                              // genuinely empty
  ins.run(7, 'html', 'x'.repeat(richLimit + 100), null);       // over cap, no byte cache
  ins.run(8, 'text', 'x'.repeat(otherLimit + 100), null);      // over cap, no byte cache
  return db;
}

test('listSqlLiteral defaults are the documented budgets', () => {
  assert.equal(richLimit, 49152);
  assert.equal(otherLimit, 8192);
});

test('listHtmlSQL trims html/rtf at the rich cap and others at the light cap', () => {
  const db = makeDb();
  const rows = db
    .prepare(`SELECT id, ${listSql} AS body FROM clipboard_items ORDER BY id`)
    .all();
  const body = Object.fromEntries(rows.map((r) => [r.id, r.body]));
  assert.ok(body[1], 'small html must ship');
  assert.equal(body[2], null, 'over-cap html must be trimmed');
  assert.ok(body[3], 'under-cap html must ship');
  assert.equal(body[4], null, 'over-cap text must be trimmed');
  assert.ok(body[5], 'under-cap text must ship');
  assert.equal(body[6], null, 'null body stays null');
  assert.equal(body[7], null, 'length() fallback must trim html');
  assert.equal(body[8], null, 'length() fallback must trim text');
  db.close();
});

test('listHtmlOmittedSQL distinguishes a trimmed body from an empty row', () => {
  const db = makeDb();
  const rows = db
    .prepare(`SELECT id, ${listOmittedSql} AS omitted FROM clipboard_items ORDER BY id`)
    .all();
  const omitted = Object.fromEntries(rows.map((r) => [r.id, r.omitted]));
  assert.equal(omitted[1], 0, 'shipped body is not omitted');
  assert.equal(omitted[2], 1, 'over-cap html must ask the wall to hydrate');
  assert.equal(omitted[3], 0);
  assert.equal(omitted[4], 1, 'over-cap text is omitted too');
  assert.equal(omitted[5], 0);
  assert.equal(omitted[6], 0, 'empty row is explicitly not omitted');
  assert.equal(omitted[7], 1, 'length() fallback signals omitted');
  assert.equal(omitted[8], 1);
  db.close();
});

test('aliased CASEs (FTS join) agree with the base CASEs', () => {
  const db = makeDb();
  const base = db
    .prepare(
      `SELECT id, ${listSql} AS body, ${listOmittedSql} AS omitted FROM clipboard_items ORDER BY id`,
    )
    .all();
  const aliased = db
    .prepare(
      `SELECT id, ${listSqlAliased} AS body, ${listOmittedSqlAliased} AS omitted FROM clipboard_items c ORDER BY id`,
    )
    .all();
  assert.deepEqual(aliased, base);
  db.close();
});
