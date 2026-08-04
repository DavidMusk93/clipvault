# Source digest: Learning a few things about running SQLite (Julia Evans)

Primary: https://jvns.ca/blog/2026/07/17/learning-about-running-sqlite/ (2026-07-17)

## Thesis

SQLite in production for a small site is fine, but it is still a database: operating it requires stats, timeouts, careful cleanup, and real backups — not only `journal_mode=WAL`.

## Lessons extracted

### ANALYZE

- FTS5 query on ~4k rows took **~5s**; after `ANALYZE` → **~0.05s**.
- `ANALYZE` builds statistics so the query planner can avoid bad plans (e.g. accidentally quadratic).
- Action: run after bulk loads / schema changes; learn `EXPLAIN QUERY PLAN` over time.

### Cleanup is tricky under one writer

- Long DELETE (e.g. completed task rows) held the write lock.
- Other worker write hit **busy_timeout (5s)** → crash → VM teardown.
- Mitigation used: **batch** cleanup so no single write exceeds the timeout.
- Alternative: scheduled maintenance window.

### ORM performance

- For small DBs (~10k rows), naive ORM is often OK **except** when planner stats are wrong.
- Growth invalidates this assumption — add indexes, FTS, ANALYZE, measurement.

### Backups

1. **restic path:** `VACUUM INTO` → gzip → restic to S3; watch OOM / lock; unlock; forget+prune retention.
2. **Litestream:** continuous replicate; config `retention` (e.g. 400h) — verify restore.
3. Monitor with dead man's switch; restore-test is often missing (do it).

### Multiple databases

- Mess with DNS: split unrelated tables across **three DB files** for 4+ years on SQLite successfully.
- Helps isolation and lock surface when cross-table transactions are unnecessary.

## Linked external refs (from article)

- Django + SQLite production guide: https://alldjango.com/articles/definitive-guide-to-using-django-sqlite-in-production
- Performance pragma gist: https://gist.github.com/phiresky/978d8e204f77feaa0ab5cca08d2d5b27
- Official: ANALYZE, FTS5, WAL, backup API
