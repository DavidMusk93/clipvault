---
doc_id: clipvault-session-store-postgres-hub-v1
kind: design
status: draft
authority: design
applies_to:
  - trae_hooks/schema.sql
  - trae_hooks/server.py
  - trae_hooks/hook_client.py
  - trae_hooks/spool_flush.py
  - trae_hooks/mine.py
  - trae_hooks/pi_session_ingest.py
  - trae_hooks/install.sh
  - trae_hooks/install_remote.sh
  - trae_hooks/pi/install_pi_hook_remote.sh
depends_on:
  - AGENTS.md
  - docs/trae-hooks.md
  - docs/session-analysis.md
supersedes: []
verified_by:
  - tests/session-store-sql.test.mjs
  - tests/session_store_pg_main.py
  - scripts/check-frontend.sh
  - manual cutover reconciliation query set (RA-1 .. RA-4)
---

# Session store: PostgreSQL 18 on d2 as the always-on hub

## 1. Decision

The ClipVault session plane stops being an **embedded DuckDB file owned by one
macOS process** and becomes a **PostgreSQL 18 server on d2**, with the existing
`trae_hooks` HTTP/SSE module kept as the only consumer-facing facade.

Three consequences are accepted explicitly:

1. **d2 owns durability.** The PostgreSQL container is the single writer for
   session data. The Mac no longer opens a session database at all.
2. **The browser contract does not move.** `ClipVault :8080/trae/*` keeps
   reverse-proxying to `127.0.0.1:9488`; on the Mac that loopback address is now
   an SSH local forward to d2. `web/index.html`, `web/session-load.mjs`,
   `Sources/ClipVault/HTTP/WebServer.swift` are unchanged.
3. **The wire timezone contract does not move.** Store timestamps stay
   naive-UTC strings on the wire (`parseHookTs` in `web/session-render.mjs`
   appends `Z`). The database column becomes `timestamptz`; the serializer
   converts back to naive UTC so no client shifts by +08:00.

Quack, the DuckDB extension, and the `:9494` listener are removed entirely.

> **Extended by** `docs/design-session-backends.md`
> (`doc_id: clipvault-session-backends-v1`, status=draft). That document adds the
> write-amplification rationale, the **session backend** plugin + aggregator
> fan-in model, the `d2 -> cc` logical-CDC replica/backup (closes `U-3`), and the
> dedicated-volume decision. Storage DDL and the rollback window stay owned by
> this document.

```text
                    one facade, one store, no embedded db on the laptop
                    ---------------------------------------------------

   browser --same origin--> ClipVault http-front --> Swift WebServer
                                                          |
                                              /trae/* --> 127.0.0.1:9488
                                                          |
                                                   [ssh -L 9488]
                                                          |
                                                          v
   ---------------------------------------------------------------
   d2
     trae_hooks module   HTTP + SSE  127.0.0.1:9488   (stateless facade)
            |
            v
     PostgreSQL 18       5432 -> 127.0.0.1:55432      (single writer)
            ^
            |  psycopg, one DSN shape everywhere
            |
   three collectors write to the same loopback address:

     d2 collector    -> 127.0.0.1:55432   same host, no tunnel
     Mac collector   -> 127.0.0.1:55432   ssh -L 55432 -> d2
     sg_d collector  -> 127.0.0.1:55432   ssh -L 55432 -> d2
```

## 2. Scope

| In scope | Artifact |
| --- | --- |
| Storage engine swap | `hook_events`, `llm_usage`, `turn_context`, `session_pins`, `analysis_acks` |
| Ingest path | `hook_client.py`, `spool_flush.py`, `row.py`, `metrics.py` (Quack -> psycopg) |
| Read/analyse path | `server.py` SQL, `mine.py` SQL, `pi_session_ingest.py` |
| Deployment | `install.sh`, `install_remote.sh`, `install_d2.sh`, `pi/install_pi_hook_remote.sh` |
| Hosting | d2 `10.37.125.152` (`Host d2`), reachable also as `d2-ts` Tailscale |
| Data | one-time migration of the 322,846-row corpus |

Users covered: the Mac ClipVault session panel, any additional ClipVault
instance that points its local forward at d2, remote Trae collectors on
d2/sg_d, the `pi` adapter on every collector machine, and Agent analysis via
`mine.py --agent` / `POST /api/mine/ack`.

## 3. Non-goals

| Non-goal | Reason |
| --- | --- |
| Offline / degraded read when d2 is unreachable | Owner decision: not required. d2 unreachable means the session panel is down, and that is accepted. |
| Month partitioning of `hook_events` in v1 | Partitioning forces the partition key into every unique index, so dedupe would become `ON CONFLICT (event_id, ts)` and `UNIQUE (raw_hash)` would weaken to per-partition. At 6.9k rows/day and ~135 MB/day, retention can stay `DELETE` + `VACUUM` until the table exceeds ~50 GB. Revisit with the cost measured. |
| Streaming replication / HA in v1 | v1 buys durability + backup (nightly `pg_dump -Fc`), not availability. A replica is a separate decision with its own RPO/RTO target. |
| Dual write or back-sync between DuckDB and PostgreSQL | Two writers on one logical corpus is the failure mode this design removes. |
| Migrating the clip clipboard SQLite (`clipflow.db`) | Different plane. `clipvault_archive_closure_sync` / CloudDocs sync are untouched. |
| ClickHouse | Evaluated and rejected. d2 already runs a `clickhouse` image, and ClickHouse would win on compression, TTL retention and scan throughput, but this corpus is 322k rows for a single user; the extra engine is not repaid. Revisit only if the corpus becomes multi-tenant or TB-scale. |
| Changing the browser-facing URL shape or the SSE event names | `tests/session-load.test.mjs`, `tests/session-thread.test.mjs`, `tests/sessions-ui.test.mjs` encode the current contract. |
| Removing DuckDB from the repository | A read-only DuckDB snapshot stays as the pre-cutover archive and rollback anchor. |

## 4. Inputs and outputs

**Inputs**

| Input | Producer | Shape |
| --- | --- | --- |
| Hook stdin JSON | Trae / pi adapter | 6 event names, arbitrary payload keys |
| `UsageReport` / `ContextReport` | `pi/clipvault-session.ts` | metrics-plane rows |
| pi session JSONL | `~/.pi/agent/sessions/**/*.jsonl` | cold-path backfill |
| Pin / ack writes | panel, Agent | `POST /api/sessions/pin`, `POST /api/mine/ack` |

**Outputs**

| Output | Consumer | Contract |
| --- | --- | --- |
| `GET /api/health` | ops, `collector_selfcheck.sh` | `{ok, role, duckdb, db, events, last_ts}` — `db` now reports the DSN target, `duckdb` is replaced by `pg` |
| `GET /api/sessions` | panel | `sessions[]` with `last_ts` as naive-UTC string |
| `GET /api/events?view=beats\|tools` | panel | beats / tool stubs |
| `GET /api/event?id=` | panel | lazy bundle body |
| `GET /api/stream` | panel | SSE: `ping`, `hook_event` |
| `GET /api/mine` | panel + Agent | four-layer analysis, `format=agent` brief |
| `POST /api/mine/ack` | Agent | writes `analysis_acks` |
| `pg_dump -Fc` | off-box backup | restorable archive |

## 5. Interfaces and ownership

| State transition | Owner | Mechanism |
| --- | --- | --- |
| Capture an event | collector machine | `clipvault_hook.sh` -> `hook_client.py`, always `exit 0` |
| Buffer when the store is unreachable | collector machine | spool JSONL under `/var/tmp/clipvault-hooks/spool` + systemd flush timer |
| Deduplicate | PostgreSQL | `hook_events.event_id` PRIMARY KEY, `hook_events.raw_hash` UNIQUE, `ON CONFLICT DO NOTHING` |
| Timestamp assignment | collector machine | `row.py: utc_now()`; **capture clock, never arrival clock** |
| Serialize timestamps to the wire | module (`server.py`) | UTC-normalised, timezone suffix stripped |
| HTTP / SSE contract | module on d2 | `server.py`, stateless with respect to storage |
| Retention, vacuum, backup | d2 PostgreSQL | cron `pg_dump -Fc`, `VACUUM (ANALYZE)` |
| Tunnel supervision | Mac console `127.0.0.1:9020` | tunnel entries `clipvault-pg-*`, `clipvault-trae-http` |

The module is deliberately **not** the owner of storage anymore: restarting it
must be a no-op for data, which is the specific property the DuckDB writer could
never provide.

## 6. Invariants

| ID | Invariant |
| --- | --- |
| `INV-1` | Exactly one writer of `hook_events` exists: the PostgreSQL instance on d2. No machine may run an alternative session store. |
| `INV-2` | `ts` is the capture clock. OCR/replay/retry/backfill must never rewrite it. A late delivery keeps its original `ts`. |
| `INV-3` | Dedupe is by `event_id` (= `raw_hash[:32]`) and `raw_hash`; redelivery of the same payload inserts zero rows. |
| `INV-4` | Hook failure is never fatal to the agent. Every collector path exits 0 and spools. |
| `INV-5` | The wire timestamp string is a naive-UTC `YYYY-MM-DD HH:MM:SS[.ffffff]`. Clients may assume trailing `Z`. |
| `INV-6` | The browser talks only to ClipVault's own origin. No page, script or iframe may call d2 or `:9488` directly. |
| `INV-7` | No payload key is silently dropped. Every un-promoted key is in the documented drop allowlist; a new unknown key raises an ingest alarm. |
| `INV-8` | `analysis_acks` keeps the latest state per `(scope, session_id, finding_id)` per window; replaying an ack is idempotent. |
| `INV-9` | Secrets never leave `chmod 600` files on disk and never enter git, nmem or chat: `CLIPVAULT_QUACK_TOKEN_FILE` is replaced by `CLIPVAULT_PG_PASSWORD_FILE`. |

## 7. Failure semantics

| Failure | Detection | Behaviour | Recovery |
| --- | --- | --- | --- |
| d2 unreachable from Mac | `ssh -L` exit, panel `error` phase | module fetch 502; spool keeps growing locally | tunnel supervisor restarts; spool drains |
| PostgreSQL down, module up | module connect error | facade returns 503 on data routes; `/api/health` reports `ok:false` | container restart; `live-restore` keeps other containers alive |
| PostgreSQL down, collector running | psycopg connect error | collector writes spool line, `exit 0` | flush timer retries every 15 s |
| Duplicate delivery (spool replay) | PostgreSQL conflict | 0 rows inserted, no SSE push | none needed |
| Malformed spool line | flush batch isolation | line quarantined to `spool/quarantine`, batch continues | inspect, fix, re-inject |
| Module restart | SIGTERM | exits cleanly (no DuckDB file lock); reconnects to PostgreSQL | `systemctl restart` |
| d2 container host reboot | uptime monitor | collectors spool; nothing lost | module + container restart, spool drains |
| Disk full on d2 | `pg_dump` failure, container logs | PostgreSQL rejects writes; spool absorbs | retention prune; Phase 3 |

The rollback window is explicitly lossy and must be stated to the user: the
Mac's DuckDB snapshot contains data **up to freeze time `T0`**. Events ingested
into PostgreSQL between `T4` and a rollback exist only in PostgreSQL, so
rolling back requires exporting the delta back into DuckDB.

## 8. Worked examples

### WX-1 Happy ingest, remote machine

Input: on sg_d, `PostToolUse` with `tool_name=RunCommand`,
`tool_response` 8,132 bytes, `session_id=sg-1`.

1. `clipvault_hook.sh` appends one JSONL line to spool and spawns the client.
2. `hook_client.py` computes `raw_hash` over the sorted-key compact payload,
   sets `event_id = raw_hash[:32]`, `ts = utc_now()` (naive UTC), and connects
   to `127.0.0.1:55432` (ssh `-L` to d2).
3. `INSERT INTO hook_events (...) VALUES (...) ON CONFLICT (event_id) DO NOTHING`.
4. Module `NOTIFY clipvault_hook`; facade pushes `hook_event` on every open SSE.
5. Panel prepends one card. `last_ts` for `sg-1` advances.

Invariant demonstrated: `INV-1`, `INV-2`. Anchor: `RA-5`.

### WX-2 Duplicate delivery

Input: the same spool line is flushed twice (tunnel bounce during flush).

1. First flush inserts the row.
2. Second flush conflicts on `event_id`; PostgreSQL reports 0 rows.
3. Module must not emit SSE for a 0-row insert.

Invariant demonstrated: `INV-3`. Anchor: `RA-6`.

Negative example: if ingest instead used `ON CONFLICT (event_id) DO UPDATE SET
ts = excluded.ts`, a retry after a clock change would silently move a historical
event to the top of the wall. That is forbidden.

### WX-3 Late event with an old capture time

Input: d2 was partitioned from the store for 3 days; a spool of 9,397 events is
flushed on 2026-09-28 with original `ts` values from 09-25..09-27.

Expected: all rows insert with their original `ts`. `last_ts` advances to the
newest capture time, and the panel's ordering is unchanged for the older rows.

Invariant demonstrated: `INV-2`. Anchor: `RA-7`.

### WX-4 Store down, agent unaffected

Input: `PreToolUse` hook fires while PostgreSQL is restarting.

1. Client connection fails after 250 ms probe (`CLIPVAULT_QUACK_PROBE_SEC`
   becomes `CLIPVAULT_PG_CONNECT_TIMEOUT_SEC`).
2. Spool line retained; process exits 0.
3. Trae proceeds. `flush.err` records the failure.

Invariant demonstrated: `INV-4`. Anchor: `RA-8`.

### WX-5 Timestamp wire round-trip

Input: a known row with DuckDB `ts = '2026-09-30 15:07:31'` (naive UTC,
verified against `max(ts)` from `/api/health` on the DuckDB store).

Before: `CAST(ts AS VARCHAR)` -> `2026-09-30 15:07:31`, frontend
`parseHookTs` -> `2026-09-30T15:07:31Z` -> local display `2026-09-30 23:07:31`.

After: column is `timestamptz` holding the same instant. The facade serialises
`to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')` -> byte-identical
`2026-09-30 15:07:31`. Local display is unchanged.

Negative example: serialising `timestamptz` with an offset suffix
(`2026-09-30T23:07:31+08:00`) or letting `psycopg` render local time would shift
every session card by 8 hours while all tests still pass — which is why this is
an anchor rather than a comment.

Invariant demonstrated: `INV-5`. Anchor: `RA-3`.

### WX-6 Forbidden: two writers

Input: an operator leaves `com.davidmusk.clipvault-trae` loaded on the Mac after
`T4`, and points the Mac collector at d2.

Result: the Mac process recreates and writes its local `hook_events.duckdb`;
some events land only there. The panel shows a random subset depending on which
tunnel is up.

Invariant demonstrated: `INV-1`. Anchor: `RA-9`.

## 9. Reconciliation anchors

| Anchor | Condition | Exact expected result | Verification |
| --- | --- | --- | --- |
| `RA-1` | Frozen DuckDB snapshot vs loaded PostgreSQL | `count(*)` equal per table: `hook_events` = 322,846 (or the freeze-time value), `llm_usage` = 5,393, `turn_context` = 5,373, `session_pins` = 0, `analysis_acks` = 1 | SQL count comparison |
| `RA-2` | Per-instance distribution | `d2` 232,706 / `mac-work` 70,813 / `sg_d` 19,327 (freeze-time values) match exactly | `GROUP BY instance_id` on both sides |
| `RA-3` | Timestamp wire identity | For 20 hand-picked rows spanning the corpus, old `CAST(ts AS VARCHAR)` equals new facade output byte-for-byte; the panel's rendered `localDateTime` is unchanged | `tests/session-store-sql.test.mjs` + manual diff |
| `RA-4` | Payload preservation after dropping `raw_json` | `sum(length(tool_response))`, `sum(length(tool_input))`, and the 96.5 %-coverage `agent_type`/`agent_id` values match the pre-migration values | SQL sum comparison |
| `RA-5` | Live ingest end-to-end | `az` probe event appears in `/api/sessions`, 1 SSE `hook_event` received, `last_ts` advances within 1 s | `tests/session_store_pg_main.py` |
| `RA-6` | Redelivery | Same payload inserted twice yields 1 row and 1 SSE event | `tests/session_store_pg_main.py` |
| `RA-7` | Late/out-of-order delivery | A row with `ts` 3 days older inserts and does not become `last_ts`; ordering for older rows unchanged | `tests/session_store_pg_main.py` |
| `RA-8` | Store down | Collector exits 0, spool grows by 1, then draining after recovery inserts exactly 1 row | `trae_hooks/collector_selfcheck.sh` + `tests/session_store_pg_main.py` |
| `RA-9` | Single-writer | After cutover, the Mac has no listener on `:9488`, no `hook_events.duckdb` open handle, and `launchctl list` shows no `com.davidmusk.clipvault-trae` | `lsof -nP -iTCP:9488 -sTCP:LISTEN` empty on Mac; `launchctl list` grep empty |
| `RA-10` | Analysis parity | `/api/mine?scope=recent&days=7` returns the same `metric.id` set and the same `fail_n`/`retry_n` values as the DuckDB baseline for the same window; p95 latency <= 3x the 640 ms DuckDB baseline | `tests/session-mine.test.mjs` + timed probe |

## 10. Evidence and unknowns

**Observed (this investigation, DuckDB baseline measured 2026-09-30).**

| Claim | Measurement |
| --- | --- |
| Corpus size | 7.37 GiB file, 6.16 GiB used, 16.5 % free, 322,846 `hook_events` rows over 47 days |
| Write rate | ~6.9k rows/day = 0.08 rows/s; d2 produces 232,706 rows / 4.37 GB (74 %) |
| Growth | ~135 MB/day |
| Duplication | `raw_json` contains `tool_response` as a prefix in 157,789 / 157,789 cases (100 %) |
| Size after dropping `raw_json` | 2.96 GiB (-60 %); truncating >256 KB responses gives only 2.83 GiB |
| Keys lost by dropping `raw_json` | `agent_type` (311,603 rows, 96.5 %), `agent_id` (311,603), `text_content` (992), payload `source` (1,003) |
| Unused today | `agent_type`, `agent_id`, `text_content` are referenced nowhere in `trae_hooks/`, `web/`, `Sources/`, `tests/` |
| Read latency | `/api/sessions?limit=300` 30 ms; `/api/mine?scope=session` 5 ms; `/api/mine?scope=recent&days=7` 640 ms |
| DuckDB is single-process | `duckdb.connect(read_only=True)` from a second process fails: `Could not set lock on file ... Conflicting lock is held ... (PID 64500)` |
| No backup today | `CloudDocsBackupService.swift` only deletes a legacy `clipflow.duckdb`; the session store is not in any backup path |
| Timezone split | `row.py: utc_now()` is naive UTC; `ingested_at DEFAULT current_timestamp` is local; median difference is exactly 28800 s on all three instances |
| Postgres availability | `postgres:18-alpine` pulled on d2 via the daemon proxy; image `sha256:c293117fcecda7344b5480222e813b9f673d7abd69b1dd95eff239b768b04f59`, digest `postgres@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873`, 304 MB |
| Port availability on d2 | `55432`, `9488`, `9594` free; `9494` occupied by an unrelated `duckdb_quack_server.py` on `0.0.0.0` |
| Web contract is origin-relative | `web/index.html:5088` uses `'/trae/?embed=1&v=s9'`; `WebServer.swift: traeBackendURL` hardcodes `127.0.0.1` with only `CLIPVAULT_TRAE_HTTP_PORT` configurable |
| SQL porting surface | `mine.py` 26 SQL sites, `server.py` 9; DuckDB-only constructs: `list()` x3, `epoch` x2, `strftime` x1; 31 `?` placeholders |

**Unknown / unresolved — must be closed before `T1`.**

| ID | Unknown | Why it blocks |
| --- | --- | --- |
| `U-1` | 2026-09-25..27 contains 0 rows, while the Mac module log shows one `GET /api/stream` per day. Whether this is "no capture" or "hub outage data loss" is undetermined. | Migrating a corpus whose hole is unexplained would freeze the defect into the new store. Determine first, then migrate either way with the finding recorded. |
| `U-2` | d2 -> sg_d SSH is denied (`Permission denied (publickey,gssapi-with-mic,password)`), and sg_d cannot resolve `d2`. | The sg_d collector needs a tunnel to d2. Either install an `sg_d -> d2` key (preferred: sg_d initiates `ssh -L`) or accept Mac-relayed forwarding, which reintroduces the unstable Mac. |
| `U-3` | d2 has no off-box backup target. | 7.37 GiB of personal history on a shared corporate dev host with no backup is the current state; the new design must name the target and prove one restore. **Resolved:** `docs/design-session-backends.md` §5 - `d2 -> cc` logical CDC (full replica via `pgoutput`), plus a nightly `pg_dump -Fc` on cc; `RA-11` restore drill. |
| `U-4` | Whether d2's host is reprovisioned on a schedule. | Determines whether PostgreSQL data lives on the root filesystem or on a separately durable volume. |
| `U-5` | Actual PostgreSQL storage size for the corpus. | Needed for the retention threshold. Estimate 1.5–3.0 GB after TOAST; must be measured post-load. |
| `U-6` | `/api/mine` latency on PostgreSQL for a 7-day window. | The 640 ms DuckDB baseline is the number to beat within 3x (`RA-10`). |

## Appendix A — Phases

```text
Phase 0  corpus hygiene (no host change, no engine change)   [do first]
   export-only: extract agent_type / agent_id / text_content
   and drop raw_json at export time instead of mutating the
   live 7.37 GiB single-writer DuckDB (raw_json is NOT NULL)
   target PostgreSQL size 2.96 GiB
   nightly off-box snapshot of the frozen DuckDB
   drop-allowlist alarm at the new ingest path (INV-7)

Phase 1  PostgreSQL on d2
   docker run postgres:18-alpine  -p 127.0.0.1:55432:5432  volume on durable path
   DDL + COPY load + index build
   run RA-1 .. RA-4  (freeze snapshot vs loaded store)

Phase 2  module moves to d2
   server.py + mine.py ported to psycopg   (no Quack, no :9494)
   collectors repointed to 127.0.0.1:55432
   Mac: bootout com.davidmusk.clipvault-trae ; add ssh -L shims
   smoke RA-5 .. RA-10

Phase 3  retention + backup gates
   nightly pg_dump -Fc -> off-box ; prove one restore
   retention DELETE + VACUUM ; revisit partitioning with measured size
```

Phase 0 deliberately does not migrate anything in place. `raw_json` is
`NOT NULL` in `trae_hooks/schema.sql`, so removing it from the write path means
`ALTER COLUMN DROP NOT NULL` plus a rewrite of a 7.37 GiB file that already has
one corrupt WAL beside it, on a writer that is known to hang on SIGTERM. The
export path reaches the same 2.96 GiB target with zero risk to the live store.

## Appendix B — Cutover sequence and rollback

```text
T0  freeze the Mac writer            launchctl bootout com.davidmusk.clipvault-trae
                                     spool absorbs on every machine (fail-open)
T1  export the frozen DuckDB         COPY (...) TO parquet   + record counts
T2  start PostgreSQL on d2           DDL, COPY load, indexes
T3  reconcile                        RA-1 .. RA-4 must pass, else abort and keep DuckDB
T4  repoint collectors               d2 loopback, Mac ssh -L, sg_d ssh -L
T5  start the module on d2           HTTP 127.0.0.1:9488 ; Mac adds ssh -L 9488
T6  panel smoke                      /api/health, /api/sessions, /api/mine, SSE, RA-9
T7  drain spools on all machines     assert last_ts advances per instance
T8  keep the DuckDB file read-only   rollback anchor for N days, then archive

rollback = T5+T4 back to the Mac writer, then export the PostgreSQL delta
           for [T4, rollback] into DuckDB. Data before T0 is in DuckDB only.
           RPO for rollback is therefore "everything since T4" unless exported.
```

## Appendix C — Dependency resolution record

| `depends_on` value | Resolved | Unique |
| --- | --- | --- |
| `AGENTS.md` | `projects/clipvault/AGENTS.md` (clipvault repository root) | yes |
| `docs/trae-hooks.md` | `projects/clipvault/docs/trae-hooks.md` | yes |
| `docs/session-analysis.md` | `projects/clipvault/docs/session-analysis.md`, front matter `doc_id: clipvault-session-analysis-v2` | yes |

No duplicate `doc_id` match, no cycle. Validation manual until a linter exists.

`docs/trae-hooks.md` is **partially superseded in substance** by this document:
its "Mac store is the only writer", Quack `:9494` and `19494/19495` tunnel
sections stop being true at `T4`. It carries no front matter, so
`supersedes: []` is used here and the revision of that file must land in the
same change as Phase 2.
