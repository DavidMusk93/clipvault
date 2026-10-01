---
doc_id: clipvault-session-backends-v1
kind: design
status: draft
authority: design
applies_to:
  - trae_hooks/schema.sql
  - trae_hooks/server.py
  - trae_hooks/hook_client.py
  - trae_hooks/spool_flush.py
  - trae_hooks/mine.py
  - trae_hooks/row.py
  - trae_hooks/metrics.py
  - trae_hooks/pi_session_ingest.py
  - trae_hooks/install.sh
  - trae_hooks/install_remote.sh
  - trae_hooks/install_d2.sh
  - trae_hooks/pi/install_pi_hook.sh
  - trae_hooks/pi/install_pi_hook_remote.sh
  - Sources/ClipVault/HTTP/WebServer.swift
  - web/index.html
  - docs/trae-hooks.md
depends_on:
  - AGENTS.md
  - docs/design-session-store-postgres-hub.md
  - docs/trae-hooks.md
  - docs/session-analysis.md
supersedes: []
verified_by:
  - tests/session-store-sql.test.mjs
  - tests/session_store_pg_main.py
  - tests/session-backend-router.test.mjs
  - scripts/check-frontend.sh
  - manual CDC failover + replica equivalence drill (RA-11, RA-12)
---

# Session backends: PostgreSQL hub + plugin fan-in

## 1. Decision

The session plane is rebuilt as **one PostgreSQL 18 corpus on d2, exposed through
a small plugin interface, fanned in by clipvault.**

1. **Engine: PostgreSQL 18 on d2**, on a **dedicated volume**. The embedded
   DuckDB store is retired; the driver is **write amplification** on the wide,
   append-mostly `hook_events` table, not throughput.
2. **clipvault owns no session rows.** It consumes a **Session API v1 (SA-v1)**
   from one or more **session backends**. A backend is a service that implements
   SA-v1 and owns a PostgreSQL store; d2 is backend `d2`, cc is backend `cc`.
3. **Fan-in is a first-class goal, and its purpose is availability/backup.** Each
   backend declares a `corpus_id`; backends that share a `corpus_id` are replicas
   of one corpus. clipvault's aggregator **fails over** within a corpus and
   **merges** across corpora.
4. **Replication: PostgreSQL logical CDC, `d2 -> cc`.** d2 is the publisher, cc
   is a full logical replica driven by `pgoutput`, so cc holds a complete,
   continuously consistent copy. No Mac is in the path.
5. **Implementation language: Rust.** The session module is the `session/` crate
   (`clipvault-session` facade + `clipvault-hook` collector); the Python
   `trae_hooks` server is deprecated. Rationale and module map in §11.

Naming: the plugin unit is a **backend** (the conventional reverse-proxy term
for the upstream that serves a route); the fan-in component is the
**aggregator**. "provider" is retired.

Root cause this removes: today every Mac runs its own
`com.davidmusk.clipvault-trae` and its own `hook_events.duckdb` (mac-home:
`~/Library/Application Support/Keepsake/trae/hook_events.duckdb`, 2 239 rows),
so there is no shared corpus at all and mac-home can never show mac-work / d2 /
sg_d sessions.

```text
   today (per-Mac island)                 target (one corpus, plugin fan-in)

   mac-home -> local duckdb  2239         mac-home --/trae/*--> aggregator --> d2
   mac-work -> local duckdb 70813         mac-work --/trae/*--> aggregator --> d2
   d2       -> quack -R -> mac            d2       (backend, local PG)
   sg_d     -> quack -R -> mac            sg_d  -> PG collector -> d2
   (no shared store)                      cc       (replica backend, via CDC)
```

## 2. Topology

```text
   browser --same origin--> ClipVault host (mac-home / mac-work)
                               |  Swift WebServer
                               |  SessionAggregator
                               |    backends.d/d2.json  corpus=clipvault prio=100
                               |    backends.d/cc.json  corpus=clipvault prio=10
                               |    transport: ssh -L (per-host lifecycle policy)
                               |
                 read: prefer healthy, highest-priority backend in the corpus
                 write (pin / ack): always the primary backend
                               |
        +----------------------+----------------------+
        v                                             v
   ------------------------------------       ------------------------------------
   d2   backend id="d2" role=primary          cc   backend id="cc" role=replica
     session module  127.0.0.1:9488             session module  127.0.0.1:9488
        |                                          |
        v                                          v
     PostgreSQL 18   127.0.0.1:55432            PostgreSQL 18  127.0.0.1:55432
       (dedicated volume)                        (dedicated volume)
        ^  |                                        ^
        |  |  logical CDC: cc subscriber  <--ssh -R 15432--  d2 publisher
        |  v
     collectors (each tags its instance_id):
       d2        -> d2:55432   same host
       mac-home  -> d2:55432   ssh -L 55432 -> d2
       mac-work  -> d2:55432   ssh -L 55432 -> d2
       sg_d      -> d2:55432   ssh -L 55432 -> d2   (sg_d -> d2 key installed)
```

One hook, end to end:

```text
   Trae / pi event
        | stdin JSON
        v
   clipvault_hook.sh --event E      (always exit 0)
        | spool JSONL first (fail-open)
        v
   hook_client.py --event E  --PG DSN--> d2:55432
        |                                   |
        |                                   v
        |                        INSERT ... ON CONFLICT (event_id) DO NOTHING
        |                                   |
        |                                   v
        |                        session module NOTIFY / SSE hook_event
        v
   replica cc receives the same commit through logical CDC (near-real-time)
```

Writers: only the primary (d2) accepts `INSERT`. The replica is read-only for
replicated tables. Reads fail over; writes never.

## 3. Session backends and the aggregator

### 3.1 Session API v1 (SA-v1, the plugin interface, frozen)

| Method | Path | Returns |
| --- | --- | --- |
| GET | `/api/health` | `{ok, role, backend_id, store, corpus_id, events, last_ts}` |
| GET | `/api/sessions` | `sessions[]`, `last_ts` as naive-UTC string |
| GET | `/api/events?view=beats\|tools&session_id=` | beats / full tool stub index |
| GET | `/api/event?id=` | lazy bundle body |
| GET | `/api/stream` | SSE `connected` / `ping` / `hook_event` |
| GET | `/api/mine` | analysis (human + `format=agent`) |
| POST | `/api/mine/ack` | idempotent `analysis_acks` write (primary only) |
| POST | `/api/sessions/pin` | pin / unpin (primary only) |

Payload shapes are unchanged from `docs/design-session-store-postgres-hub.md` §4
and `docs/session-analysis.md`. The plugin layer adds discovery, grouping and
transport; it never changes a payload.

### 3.2 Backend descriptor (the plugin artifact)

Location: `~/.config/clipvault/backends.d/<id>.json` (per host).
`CLIPVAULT_SESSION_DEFAULT` selects the default backend id.

```json
{
  "id": "d2",
  "label": "d2 primary",
  "api_version": 1,
  "corpus_id": "clipvault",
  "role": "primary",
  "priority": 100,
  "store": { "engine": "postgresql", "host": "d2", "database": "clipvault" },
  "instance_ids": ["d2", "sg_d", "mac-home", "mac-work"],
  "transport": {
    "kind": "ssh-local-forward",
    "ssh_host": "d2",
    "remote_port": 9488,
    "local_port": 29488,
    "lifecycle": "on-demand"
  },
  "base_url": "http://127.0.0.1:29488"
}
```

- `corpus_id` groups replicas; `priority` orders them inside a group (higher
  wins). `role` is `primary` (accepts writes) or `replica` (read-only).
- `transport.kind` is `loopback`, `ssh-local-forward`, or `direct-https`.
- `transport.lifecycle` is a **design preference, not hardcoded**: `external`
  (forward managed elsewhere), `always-on` (the initiating host's tunnel panel
  keeps it up), or `on-demand` (panel raises it on first request, idle-reaps).
  The lifecycle is owned by the **initiating machine's tunnel panel** (the
  `127.0.0.1:9020` manager on each Mac); clipvault only requires that
  `base_url` becomes reachable.

### 3.3 Aggregation model

| Scope | Behaviour |
| --- | --- |
| Within one `corpus_id` (d2, cc) | **Failover.** `/api/health` the members, pick the highest-priority healthy one. Never merge members of the same corpus: they hold the same rows, so merging would double-count. |
| Across corpora | **Merge.** Fetch the winning member of each corpus and union `sessions[]` (dedupe by `event_id`). Today there is one corpus; the mechanism exists for future corpora. |
| Writes (`pin`, `ack`) | Route to the corpus's `role=primary` member, always. Replicas reject writes. |
| SSE `/api/stream` | Bind to the winning member of the requested corpus. On drop, reconnect to the next member. Cross-corpus SSE multiplexing is deferred (see §6). |
| Cache | Stale-while-revalidate per corpus; a cache entry records the `backend_id` that served it so failover is observable. |

### 3.4 Router rules

| Request | Resolved backend |
| --- | --- |
| `/trae/b/<id>/<rest>` | backend `<id>` explicitly (debug / drill) |
| `/trae/c/<corpus>/<rest>` | winning member of that corpus |
| `/trae/<rest>`, `CLIPVAULT_SESSION_DEFAULT` set | default backend's corpus |
| `/trae/<rest>`, no config | first healthy backend in registry order |

`WebServer.traeBackendURL(from:)` becomes
`SessionAggregator.backendURL(for:)`. The browser contract does not move:
`web/index.html` still iframes `/trae/?embed=1&v=s9` and never learns a backend
id. `CLIPVAULT_TRAE_HTTP_PORT` survives only as the implicit single-backend
fallback so an un-migrated host behaves exactly as today.

### 3.5 Rules that keep ownership honest

- `INV-B1`: a backend's `/api/health` must echo `backend_id`, `store`,
  `corpus_id`, `role`. A façade that owns no PostgreSQL store is not a backend.
- `INV-B2`: every reachable endpoint comes from a descriptor; the router
  hardcodes no host/port. Adding a backend is adding one JSON file.
- `INV-B3`: an unhealthy corpus with no healthy member makes the panel `error`;
  the router never silently serves a *different corpus* under the same route.
- `INV-B4`: writes reach only a `role=primary` member; a replica is read-only.

## 4. Engine: PostgreSQL 18 replaces DuckDB (write amplification)

The corpus is tiny (0.08 events/s), so this is a per-row write-cost and
single-point-of-failure problem, not a throughput problem.

| Dimension | DuckDB (embedded) | PostgreSQL 18 (d2) |
| --- | --- | --- |
| Wide-row write cost | Row/row-group rewrite per touched row; `raw_json` is `NOT NULL` and duplicates `tool_response` in 157 789 / 157 789 rows (100 %), so each logical insert pays the full payload again. | Heap row; big `tool_response` / `tool_input` pushed to TOAST, never rewritten by narrow updates. |
| Conflict cost | `ON CONFLICT (event_id)` probes the PK ART; `raw_hash UNIQUE` + 3 secondary indexes = 5 structures per insert; single-file checkpoint rewrites. | Same index count, but MVCC + autovacuum reclaim; no whole-file checkpoint. |
| Space reclaim | String heap weakly reclaimed; file only grows (7.37 GiB / 322 846 rows; ~2.96 GiB after dropping `raw_json`). | Autovacuum / `VACUUM FULL` / `pg_repack`. |
| Concurrency | One process; a second `connect(read_only=True)` fails with `Conflicting lock is held`. | Native concurrent readers, one writer. |
| Failure domain | Hung writer = whole plane down (`SIGTERM` needs `kickstart -k`). | The module is stateless w.r.t. storage; restart is a no-op for data. |
| Remote write | Quack, a beta core extension with platform binaries, token + `disable_ssl`. | libpq; the DSN is byte-identical locally and over `ssh -L`. |
| Replication/backup | None. | Logical CDC to cc; `pg_dump -Fc`; optional PITR. |

Rejected: **ClickHouse** (compression/TTL does not repay a second engine on a
single-user 322 k-row corpus); **physical streaming replication** alone as the
CDC mechanism (cannot do the selective/consistent snapshot + slot model we want
here, and pins a byte-identical major version); **keeping DuckDB read-only as the
primary** (the second-reader lock is the original defect).

## 5. Replication and backup: `d2 -> cc` logical CDC

```text
   d2 (publisher)                                   cc (subscriber)
   -------------                                    ---------------
   wal_level = logical                              PostgreSQL 18
   CREATE PUBLICATION clipvault_pub                 CREATE SUBSCRIPTION clipvault_sub
     FOR ALL TABLES;                                  CONNECTION 'host=127.0.0.1
   max_slot_wal_keep_size = 10GB                                 port=15432
                                                                 dbname=clipvault
                                                                 user=repl ...'
   ssh -N -R 127.0.0.1:15432:127.0.0.1:55432 cc    PUBLICATION clipvault_pub
   (systemd clipvault-pg-publish-tunnel)             WITH (copy_data=true,
                                                          streaming=true);
```

- **Direction.** Logical replication is a pull: the subscriber (cc) connects to
  the publisher (d2). cc is a public VPS and cannot reach the corporate d2, so
  **d2 opens a reverse tunnel to cc** (`ssh -R 127.0.0.1:15432:127.0.0.1:55432 cc`,
  d2's existing `id_ed25519`). cc's subscription then points at
  `127.0.0.1:15432`. No Mac is involved.
- **Full copy.** `copy_data=true` snapshots the whole corpus on subscribe;
  `streaming=true` streams in-progress transactions thereafter. cc is a
  complete, continuously consistent replica (RPO ~ seconds).
- **Slot hygiene.** `max_slot_wal_keep_size` bounds WAL retained for a stalled
  subscriber; a stalled slot must never fill d2. Monitor
  `pg_replication_slots.{active,restart_lsn,confirmed_flush_lsn}` and
  `pg_stat_subscription`; alert on lag > 60 s or `active=false`.
- **Independent restore points.** In addition to the live replica, cc runs a
  nightly `pg_dump -Fc` of itself to local storage (cheap insurance against
  logical corruption that CDC would faithfully copy).
- **Restore drill** into a throwaway database is a release gate (`RA-11`), not a
  one-time act.
- **Dedicated volume.** Both d2 and cc place `PGDATA` on a dedicated volume, not
  the root filesystem, so host reprovisioning does not touch the corpus.

## 6. Correctness contract

### 6.1 Invariants

| ID | Invariant |
| --- | --- |
| `INV-1` | Exactly one primary corpus per `corpus_id`: the PostgreSQL instance on the `role=primary` backend. No Mac runs an alternative session store. |
| `INV-2` | `ts` is the capture clock; late/backfilled events keep their original `ts`. |
| `INV-3` | Dedupe by `event_id` (= `raw_hash[:32]`) and `raw_hash`; redelivery inserts zero rows. |
| `INV-4` | Hook failure is never fatal; every collector path exits 0 and spools. |
| `INV-5` | The wire timestamp string is naive-UTC `YYYY-MM-DD HH:MM:SS[.ffffff]`. |
| `INV-6` | The browser talks only to clipvault's own origin. No page, script or iframe calls a backend or `:55432` directly. |
| `INV-7` | No payload key is silently dropped; un-promoted keys live in the drop allowlist and a new key raises an ingest alarm. |
| `INV-B1` | Session rows live in exactly one primary PostgreSQL per corpus; clipvault persists no session rows. |
| `INV-B2` | As §3.5. |
| `INV-B3` | As §3.5. |
| `INV-B4` | As §3.5. |

### 6.2 Failure semantics

| Failure | Detection | Behaviour | Recovery |
| --- | --- | --- | --- |
| primary d2 unreachable from a Mac | tunnel `ssh -L` exit, aggregator probe | reads fail over to replica `cc`; writes queue in the panel | tunnel panel restores the forward; primary resumes |
| replica cc unreachable | aggregator probe | reads stay on primary; replication slot lags | tunnel/subscriber restarts; slot catches up |
| replication slot stalled | `pg_stat_subscription` / slot lag | warning; `max_slot_wal_keep_size` protects d2 disk | bring cc back; if past the limit, re-`copy_data` |
| PostgreSQL down, module up | module connect error | `503` on data routes; `/api/health` `ok:false` | container restart; `live-restore` keeps peers alive |
| collector while store down | psycopg connect error | spool line, `exit 0` | 15 s flush retries |
| duplicate delivery | PG conflict | 0 rows, no SSE push | none |
| malformed spool line | batch isolation | quarantined to `spool/quarantine` | inspect, fix, re-inject |
| module restart | SIGTERM | clean exit (no file lock); reconnect | `systemctl restart` |
| corpus fully down | aggregator | panel `error` | none (accepted: no offline read) |

### 6.3 Deliberate non-goals

| Non-goal | Reason |
| --- | --- |
| Cross-corpus SSE multiplexing in v1 | One corpus exists today; failover SSE already covers it. Revisit with a second corpus. |
| Merging members of one corpus | They are replicas; merging double-counts. |
| Offline/degraded read on a Mac | Accepted. A Mac holds no session store. |
| Automatic failover promoting a replica to primary | Primary is fixed (d2). Promotion is a separate HA decision. |
| Writing session rows from a client | Only collector `INSERT`s; the display plane is read + pin/ack. |
| Provider naming | Retired in favour of backend / aggregator. |

## 7. Performance plan (after architecture and correctness)

Order matters: architecture, then **correct**, then **fast**.

| Layer | Target implementation |
| --- | --- |
| Module | ASGI (Starlette/uvicorn) + `psycopg3` **async** + `psycopg_pool.AsyncConnectionPool`; one dedicated `LISTEN clipvault_hook` connection fanning `hook_event` to SSE clients; server-side prepared statements on the hot read paths. |
| Reads | `/api/sessions` as a single aggregate query per backend (no N+1); covering indexes; `BRIN(ts)` for the append-only scans; `timestamptz` with UTC serialization. |
| Bulk load | `COPY` into an `UNLOGGED` staging table, then `INSERT ... SELECT` into the logged table, then build indexes once. |
| Aggregator | concurrent probe + fetch with a per-backend timeout budget; stale-while-revalidate; winner memoised per corpus with a short TTL. |
| CDC | `streaming=true`; `max_slot_wal_keep_size` bounded; replica reads offload the primary. |
| Budgets | `/api/sessions?limit=300` p95 <= 30 ms (DuckDB baseline 30 ms); `/api/mine?scope=recent&days=7` <= 3x the 640 ms DuckDB baseline (`RA-10`). |

Correctness precedes these knobs: the endpoints, invariants and reconciliation
anchors must pass before any tuning.

## 8. Hook change matrix

The pi `.ts` adapter does not change; only the env it sources changes.

| Host | Trae hook | pi hook | Was | Becomes |
| --- | --- | --- | --- | --- |
| mac-home | `~/.trae-cn/hooks.json` | `~/.pi/agent/extensions/clipvault-session.ts` | Quack into its **own** Mac DuckDB | `CLIPVAULT_PG_DSN` -> `127.0.0.1:55432` via `ssh -L -> d2` |
| mac-work | `~/.trae-cn/hooks.json` | same | Quack `:19494` -R -> mac-work DuckDB | same DSN shape; `ssh -L -> d2` |
| d2 | `/root/.trae-cn/hooks.json` | `/root/.pi/agent/extensions/...` | Quack `127.0.0.1:19494` | `127.0.0.1:55432`, same host, no tunnel |
| sg_d | `/root/.trae-cn/hooks.json` | same | Quack `127.0.0.1:19495` | `ssh -L 55432 -> d2` (sg_d -> d2 key installed) |

Env contract change (collector side):

| Old | New |
| --- | --- |
| `CLIPVAULT_QUACK_URI=quack:127.0.0.1:<port>` | `CLIPVAULT_PG_DSN=postgresql://clipvault@127.0.0.1:55432/clipvault` |
| `CLIPVAULT_QUACK_TOKEN_FILE=.../quack.token` | `CLIPVAULT_PG_PASSWORD_FILE=.../pg.password` (`chmod 600`) |
| `CLIPVAULT_QUACK_PROBE_SEC=0.25` | `CLIPVAULT_PG_CONNECT_TIMEOUT_SEC=0.25` |
| venv `duckdb==1.5.5` + quack extension | venv `psycopg[binary]` + `psycopg_pool` |

Retired everywhere: Quack, `:9494`, reverse tunnels `clipvault-quack-d2` /
`clipvault-quack-sg_d`, remote ports `19494` / `19495`, `trae-quack.token`, the
macOS LaunchAgent `com.davidmusk.clipvault-trae`, and each Mac's local
`trae/hook_events.duckdb` (kept only as a frozen rollback anchor, never reopened).

## 9. Migration phases

```text
Phase 0  corpus hygiene (no host change, no engine change)
   export-only: extract agent_type / agent_id / text_content,
   drop raw_json at export time; record the free-delta.   [hub doc Phase 0]

Phase 1  PostgreSQL on d2 (dedicated volume)
   provision the volume; docker postgres:18-alpine -p 127.0.0.1:55432:5432
   DDL (timestamptz; raw_json gone) + COPY load + indexes
   reconcile RA-1 .. RA-4 against the frozen DuckDB snapshot

Phase 2  backend module on d2
   server.py / mine.py / ingest ported to psycopg (no Quack, no :9494)
   SA-v1 at d2 127.0.0.1:9488; /api/health echoes backend_id=d2 role=primary

Phase 3  replica backend on cc + logical CDC
   cc: PostgreSQL 18 on its own volume; d2 -> cc reverse tunnel; subscription
   RA-11 restore drill; slot-lag alerting

Phase 4  clipvault becomes a client (fan-in)
   SessionAggregator + backends.d/{d2,cc}.json; lifecycle policy per host
   mac-home cuts straight to d2 (no local backend)
   RA-12: mac-home reads the same event_id set as d2's own view

Phase 5  collectors repointed + retirement
   d2 local; mac-home / mac-work via ssh -L 55432; sg_d via ssh -L + installed key
   bootout com.davidmusk.clipvault-trae on every Mac
   remove Quack, :9494, reverse tunnels, trae-quack.token
   RA-5 .. RA-9
```

Rollback = Phase 5 back to the previous installers plus the frozen DuckDB anchor;
the lossy window is "rows committed to PostgreSQL after the freeze", identical to
the hub doc's Appendix B.

## 10. Open items and reconciliation anchors

| ID | Item | Needed before |
| --- | --- | --- |
| `O-1` | Exact `transport.lifecycle` default per host (proposed `on-demand` on Macs, `always-on` on d2/cc). | Phase 4 |
| `O-2` | Replication user/grants and password delivery path on d2/cc. | Phase 3 |
| `O-3` | cc's own `PGDATA` volume path and the nightly `pg_dump` retention there. | Phase 3 |
| `U-4` | Is d2 reprovisioned on a schedule? Sets the dedicated-volume provisioning path. | Phase 1 |
| `U-5` | Actual PostgreSQL size after load (estimate 1.5-3.0 GB); sets any retention threshold. | Phase 1 |
| `U-6` | `/api/mine?scope=recent&days=7` latency (gate <= 3x the 640 ms baseline). | Phase 2 |

| Anchor | Condition | Exact expected result | Verification |
| --- | --- | --- | --- |
| `RA-11` | Replica / backup is restorable | `pg_restore` of cc's dump into a throwaway DB succeeds; row counts match `RA-1` | restore drill |
| `RA-12` | Replica equivalence | For the same window, d2 and cc return the same `event_id` set; aggregator failover to cc changes `backend_id` but not the rows | `tests/session-backend-router.test.mjs` + manual |
| `RA-13` | Backend health proves ownership | `/api/health` echoes `backend_id`, `store`, `corpus_id`, `role`; the router refuses a backend otherwise | `tests/session-backend-router.test.mjs` |

## 11. Implementation language: Rust

Python is retired for the session plane. The `session/` crate owns it:

```text
   session/
     src/lib.rs        wire_ts (naive-UTC, INV-5)
     src/config.rs     one DSN shape; password from a chmod 600 file
     src/db.rs         deadpool pool + LISTEN fan-out + typed row -> JSON
     src/model.rs      hook payload -> hook_events row; SSE stub; spool
     src/facade.rs     SA-v1 handlers (health/sessions/events/event/stream/pin/mine)
     src/bin/clipvault-session.rs   facade service
     src/bin/clipvault-hook.rs      fail-open collector
     schema.sql        PostgreSQL DDL
     deploy/clipvault-session.service
```

Why Rust here: the collector runs on every hook (process spawn per event) so
startup and memory matter; the facade is a long-lived networked service where a
single async runtime with bounded, typed connection pooling is a better fit than
threads + an untyped driver; and `tokio-postgres` gives `LISTEN`/`NOTIFY` and
`pgoutput`-adjacent primitives without a platform extension.

Ordering stays architecture -> correctness -> performance: the endpoints,
invariants and reconciliation anchors are pinned before any tuning knobs. The
Python `trae_hooks` files remain in the tree only until the client-side cutover
(`docs/trae-hooks.md` is the migration reference), and are not modified by this
design.

## Appendix A - Relationship to the hub design

`docs/design-session-store-postgres-hub.md`
(`clipvault-session-store-postgres-hub-v1`) already fixed the PostgreSQL move to
d2, the façade contract, the wire timezone rule and the dedupe rules; it is
retained. This document adds what it left open: the **write-amplification
rationale**, the **plugin fan-in** model (backends + aggregator), the
**`d2 -> cc` logical CDC** replica/backup (closes `U-3`), and the dedicated-volume
decision. Where they differ, this document wins for client/fan-in/replication
behaviour; the hub document wins for the storage DDL and the cutover rollback
window.
