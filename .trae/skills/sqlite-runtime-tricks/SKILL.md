---
name: sqlite-runtime-tricks
description: >-
  SQLite production/runtime operating tricks (not SQL syntax 101): WAL, busy timeout,
  ANALYZE/PRAGMA optimize, batch cleanup under writer lock, online backup, FTS5 planner
  pitfalls, multi-file split, connection pragmas. Use when designing, reviewing, or tuning
  SQLite in apps/daemons (Keepsake/ClipFlow, local web, Django+SQLite, macOS services),
  when queries are mysteriously slow, writers time out, WAL grows, backups are hot-file
  copies, or the user mentions SQLite ops / jvns / litestream / VACUUM INTO. Slash: /sqlite-runtime-tricks
---

# SQLite Runtime Tricks

Agent checklist for **running** SQLite as a real database. Derived from
[Julia Evans — Learning a few things about running SQLite](https://jvns.ca/blog/2026/07/17/learning-about-running-sqlite/)
plus the commonly-cited [phiresky pragma gist](https://gist.github.com/phiresky/978d8e204f77feaa0ab5cca08d2d5b27)
and official docs. Prefer applying these before blaming the language/ORM.

## When to load

- New SQLite-backed service / daemon / desktop DB layer
- "Search/query got slow after data grew"
- Writer timeouts, worker crash on `SQLITE_BUSY`, cleanup jobs hang the app
- Backup/restore design for a live DB
- Review of Keepsake / ClipFlow / any single-file SQLite product

## Mental model

| Fact | Consequence |
| --- | --- |
| SQLite is still a database | Needs stats, indexes, timeouts, backup strategy — not just `CREATE TABLE` |
| Default is one writer | Long transactions block other writers; batch work |
| WAL helps readers+writer concurrency | Enable WAL; still not multi-writer like Postgres |
| Query planner needs stats | Stale/missing stats → bad plans (accidentally quadratic) |
| Hot file copy is not a backup | Use `sqlite3_backup`, `VACUUM INTO`, or Litestream |

## 1. Connection pragmas (every open)

Run on **each** connection after `sqlite3_open` (some persist, some are per-connection):

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;   -- safe with WAL; much less fsync than FULL
PRAGMA busy_timeout = 5000;    -- ms; match app SLA; avoid instant SQLITE_BUSY
PRAGMA temp_store = MEMORY;
PRAGMA foreign_keys = ON;
-- optional, size to workload:
PRAGMA mmap_size = 268435456;  -- 256 MiB virtual; OS manages pages
PRAGMA cache_size = -64000;    -- ~64 MiB page cache (negative = KiB)
```

Notes:

- `synchronous=NORMAL` + WAL is the usual production compromise (see SQLite pragma docs).
- `page_size` only matters before first pages are written (or after full `VACUUM`). Do not casually change on live DBs.
- Large BLOB-heavy DBs may benefit from larger `page_size` **on create**; measure first.

## 2. `ANALYZE` / `PRAGMA optimize` (jvns: 5s → 0.05s)

**Symptom:** Small tables, "should be fast" queries (especially FTS5 joins) take seconds.

**Action:**

```sql
ANALYZE;                 -- rebuild planner stats now
PRAGMA optimize;         -- recommended on connection close; long-lived apps: every few hours
```

Rules for agents:

1. After schema create, bulk import, or FTS rebuild → run `ANALYZE`.
2. Long-lived process → schedule `PRAGMA optimize` (and optionally `ANALYZE` if plans degrade).
3. Before tuning indexes for a "mystery slow query", run `ANALYZE` and re-time; then `EXPLAIN QUERY PLAN`.
4. FTS5 is **not** exempt — planner can still choose a terrible path without stats.

## 3. Cleanup under a single writer (jvns worker crash)

**Symptom:** One long `DELETE`/`UPDATE` holds the write lock; other worker hits `busy_timeout` and dies.

**Do:**

```text
loop:
  DELETE ... WHERE ... LIMIT N;   -- or keyset batch by id/timestamp
  COMMIT / end short transaction
until changes = 0
```

**Don't:** multi-minute single transaction of Python/Swift business logic + bulk SQL while the live app also writes.

Alternatives: maintenance window / pause writers; or offload heavy tables to a second DB file (see §6).

## 4. Backup (pick one; test restore)

| Method | Use when |
| --- | --- |
| **`sqlite3_backup` API** | Online consistent backup while app runs (preferred for daemons) |
| **`VACUUM INTO 'path'`** | Point-in-time file for restic/S3; locks more than backup API |
| **Litestream** | Continuous/incremental replication to S3-compatible storage |
| **cp of live `.db`** | Almost never — torn pages / missing WAL |

Ops checklist:

- Prefer SHA skip / content-addressed "latest" + sparse snapshots (Keepsake CloudDocs pattern).
- Monitor with a dead-man switch; **actually restore-test** occasionally.
- After backup destination open, `PRAGMA wal_checkpoint(FULL)` on the copy if needed for a single-file artifact.
- WAL can grow without bound under write pressure → periodic `PRAGMA wal_checkpoint(PASSIVE|FULL|TRUNCATE)`.

## 5. Search / FTS5

- Prefer **FTS5** over leading-wildcard `LIKE '%q%'` once rows leave toy scale.
- External-content or explicit dual-write FTS table; keep triggers / app code in sync on INSERT/UPDATE/DELETE.
- After building FTS: `ANALYZE` (and `INSERT INTO fts(fts) VALUES('optimize')` when appropriate).
- If FTS suddenly slow: stats first, then query plan — not "rewrite in Postgres" yet.
- **Fuzzy / substring:** use `tokenize='trigram'` when SQLite ≥ 3.34 (macOS ships it). Rebuild FTS if tokenizer changes; hybrid = FTS first, `LIKE` fallback for &lt;3 chars or empty FTS.
- Rank with `ORDER BY bm25(fts), timestamp DESC` when joining to base table.

## 5b. Latest-alive + periodic dedupe (clipboard / event streams)

Same payload re-copied must **not** insert a new primary key forever.

| Layer | Practice |
| --- | --- |
| **Write path** | Upsert by `content_hash`: hit → `UPDATE timestamp, copy_count+1` (stable id); miss → `INSERT` |
| **Periodic cleanup** | Every N minutes, **batch** delete losers (`LIMIT 50`) where another row shares `content_hash` and is newer — same spirit as §3, not one giant `DELETE` |
| **Orphans** | After base deletes, prune FTS ids missing from base (also batched) |
| **Don't** | One-shot “cleanup script” as the only strategy; rely on write-path + continuous drain |

## 6. Multiple database files

If tables do not need the same transaction, **split files** (jvns Mess with DNS pattern):

- Reduces lock contention and backup blast radius
- Attach only when needed: `ATTACH 'other.db' AS other;`
- Keepsake-style: metadata+text vs huge BLOBs can be a future split if BLOB IO dominates

## 7. Review checklist (agent)

When reviewing or implementing SQLite code, verify:

- [ ] WAL on (or explicit reason for DELETE journal)
- [ ] `busy_timeout` > 0 aligned with callers
- [ ] Single writer serialized (queue / connection pool discipline)
- [ ] List/API paths do not `SELECT` huge BLOBs
- [ ] Indexes match ORDER BY / keyset cursors / filter columns
- [ ] Search path is FTS or bounded scan — not four unindexed `LIKE %q%`
- [ ] Bulk deletes/updates are **batched** under short transactions
- [ ] Backup uses `sqlite3_backup` or `VACUUM INTO`, not hot `cp`
- [ ] `ANALYZE` / `PRAGMA optimize` scheduled for long-lived processes
- [ ] WAL checkpoint strategy if write-heavy
- [ ] Restore path re-applies pragmas after reopen

## 8. Keepsake / ClipFlow binding

Product DB: `CLIPVAULT_HOME`/`KEEPSAKE_HOME` `clipflow.db` (mac-home: `~/Library/Application Support/Keepsake`). `DatabaseManager` is **one writer** (`db` + `dbQueue`) plus a **WAL read-only** connection (`readDB` + `readQueue`). WAL without a second connection is not concurrency.

Must-have runtime profile for this product:

1. Connection pragmas in §1 on **every** open (writer and reader) and after restore reopen  
2. FTS5 **trigram** (fallback unicode61) + bm25; LIKE only for &lt;3 chars or FTS-empty **non-FTS fields** (`user_note`/`url`). Never `LIKE html_content`  
3. `ANALYZE` after schema/FTS bootstrap; `PRAGMA optimize` + FTS optimize on a slow timer  
4. CloudDocs: `sqlite3_backup` then dest `VACUUM INTO` — never hot-copy; never `VACUUM` the **live** writer  
5. `auto_vacuum=INCREMENTAL` only on empty files; existing DBs stay NONE. `incremental_vacuum` only if `PRAGMA auto_vacuum=2`  
6. `clearAll` / mass delete / dedupe → batched short transactions  
7. List: no `image_data`; no archive HTML; `html_bytes` gate (do not `length()` overflow pages); keyset `(timestamp DESC, id DESC)`  
8. Archive body = CAS `archive_html_sha` + `blobs/{sha}.bin`. Do not write archive HTML back into `html_content`  
9. **Latest-alive** upsert by `content_hash` + **10min batched** dupe drain (not one-shot only)

## 9. References

- https://jvns.ca/blog/2026/07/17/learning-about-running-sqlite/
- https://sqlite.org/lang_analyze.html
- https://sqlite.org/pragma.html#pragma_optimize
- https://sqlite.org/fts5.html
- https://sqlite.org/backup.html
- https://sqlite.org/wal.html
- https://litestream.io/
- https://gist.github.com/phiresky/978d8e204f77feaa0ab5cca08d2d5b27
- https://alldjango.com/articles/definitive-guide-to-using-django-sqlite-in-production

Local mirror of source notes: `references/jvns-sqlite-ops.md` in this skill directory.
