---
doc_id: clipvault-session-provider-v1
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
  - tests/session-provider-router.test.mjs
  - scripts/check-frontend.sh
  - manual backup restore drill (RA-11)
---

# Session as a plugin: provider-owned PostgreSQL + one display input API

## 1. Decision

The session plane is rebuilt on three decisions that replace the current
"one embedded DuckDB per Mac + Quack reverse tunnels" shape.

1. **Engine: PostgreSQL 18 on d2.** The embedded DuckDB store is retired. The
   blocker is **write amplification** on a wide, append-mostly table, not
   throughput. `docs/design-session-store-postgres-hub.md` already moved the
   engine; this document keeps that and fixes the parts it left open.
2. **Ownership: clipvault never stores session rows.** The session panel is a
   *client*. It reads a **Session Input API (SIA v1)** from a **provider**.
   Whoever serves PostgreSQL-backed session data is a provider, and the built-in
   provider module is that same `trae_hooks` HTTP/SSE facade (now PostgreSQL,
   colocated with its store). d2 is provider `d2`.
3. **Backup: `d2 -> ssh cc`, never through a Mac.** Nightly `pg_dump -Fc`
   streamed over d2's existing `id_ed25519` to `cc.guohuasun.com`. This closes
   `U-3` from the hub design.

The concrete pain this removes: today every Mac runs its own
`com.davidmusk.clipvault-trae` and its own `hook_events.duckdb` (mac-home:
`~/Library/Application Support/Keepsake/trae/hook_events.duckdb`, 2 239 rows),
so the session wall on mac-home can never show mac-work / d2 / sg_d sessions.
There is no shared corpus, not even a broken one.

```text
   today (per-Mac island)                 target (one hub, many clients)

   mac-home  -> local duckdb  2239        mac-home  --/trae/*--> provider d2
   mac-work  -> local duckdb 70813        mac-work  --/trae/*--> provider d2
   d2        -> quack -R -> mac           d2        --/trae/*--> provider d2 (local)
   sg_d      -> quack -R -> mac           sg_d   -> PG collector -> d2
   (no shared store)                      (one PG corpus, instance_id tags)
```

## 2. Engine rationale: why DuckDB loses on write amplification

The corpus is small (0.08 events/s), so this was never a throughput problem.
It is a per-row write cost and an operational single-point problem.

| Dimension | DuckDB (embedded file) | PostgreSQL 18 (d2) |
| --- | --- | --- |
| Wide-row write cost | Row/row-group rewrite on every touched row; `raw_json` is `NOT NULL` and duplicates `tool_response` in 157 789 / 157 789 rows (100 %). One logical insert pays the full payload again. | Heap row, big `tool_response` / `tool_input` pushed to TOAST and never rewritten by narrow-column updates. |
| Conflict cost | `ON CONFLICT (event_id)` probes the PK ART; `raw_hash UNIQUE` plus 3 secondary indexes means 5 index structures maintained per insert. | Same index count, but MVCC + autovacuum reclaim; no whole-file checkpoint. |
| Space reclaim | String heap is weakly reclaimed; the file only grows (7.37 GiB for 322 846 rows; ~2.96 GiB after dropping `raw_json`). | Autovacuum / `VACUUM FULL` / `pg_repack`. |
| Concurrency | One process only; a second `connect(read_only=True)` fails with `Conflicting lock is held`. | Native concurrent readers, one writer. |
| Failure domain | A hung writer hangs the whole plane (`SIGTERM` needs `kickstart -k`). | The facade is stateless w.r.t. storage; restarting it is a no-op for data. |
| Remote write | Quack, a beta core extension with platform-specific binaries, token + `disable_ssl`. | libpq; the DSN is byte-identical locally and over `ssh -L`. |
| Backup | None. | `pg_dump -Fc` + optional WAL archiving. |

Rejected: **ClickHouse** (d2 already runs one, but compression/TTL on a
single-user 322 k-row corpus does not repay a second engine); **keeping DuckDB
read-only as the primary** (the second-reader lock is the original defect).

## 3. Target topology

```text
   browser --same origin--> ClipVault host (mac-home / mac-work)
                               |  Swift WebServer
                               |  SessionProviderRouter
                               |    config: providers.d/d2.json
                               |    transport: ssh -L <local> -> d2:9488
                               |
                               v
   ------------------------------------------------------------------
   d2  (provider id = "d2", owns the only session store)
     session module (trae_hooks/server.py)  HTTP + SSE  127.0.0.1:9488
             |
             v
     PostgreSQL 18   127.0.0.1:55432 (docker -p loopback only)
             ^
             |  psycopg, one DSN shape everywhere
             |
     collectors (each tags its instance_id):
       d2        -> 127.0.0.1:55432   same host, no tunnel
       mac-home  -> 127.0.0.1:55432   ssh -L 55432 -> d2
       mac-work  -> 127.0.0.1:55432   ssh -L 55432 -> d2
       sg_d      -> 127.0.0.1:55432   ssh -L 55432 -> d2   (see U-2b)

   backup (d2 -> cc, no Mac in the path)
     d2 cron 02:30 UTC:  pg_dump -Fc | ssh cc "cat > /backup/clipvault/..."
```

Data flow of one hook:

```text
   Trae / pi event
        | stdin JSON
        v
   clipvault_hook.sh --event E      (always exit 0)
        | spool JSONL first (fail-open)
        v
   hook_client.py --event E  --PG DSN--> 127.0.0.1:55432
        |                                     |
        |                                     v
        |                          INSERT ... ON CONFLICT (event_id) DO NOTHING
        |                                     |
        |                                     v
        |                          session module NOTIFY / SSE hook_event
        v
   (spool retained until insert acknowledged; flush timer retries every 15 s)
```

## 4. Provider plugin contract (Session Input API v1)

A **provider** is any service that (a) implements SIA v1 and (b) owns a
PostgreSQL session store. ClipVault registers providers as data files and routes
`/trae/*` to the resolved provider.

### 4.1 SIA v1 endpoints (the plugin interface, frozen)

| Method | Path | Returns |
| --- | --- | --- |
| GET | `/api/health` | `{ok, role, provider_id, pg, db, events, last_ts}` — `pg` replaces `duckdb`; `provider_id` and `store` prove ownership |
| GET | `/api/sessions` | `sessions[]`, `last_ts` as naive-UTC string |
| GET | `/api/events?view=beats\|tools&session_id=` | beats / full tool stub index |
| GET | `/api/event?id=` | lazy bundle body |
| GET | `/api/stream` | SSE `connected` / `ping` / `hook_event` |
| GET | `/api/mine` | analysis (human + `format=agent`) |
| POST | `/api/mine/ack` | idempotent `analysis_acks` write |
| POST | `/api/sessions/pin` | pin / unpin |

The wire contract is unchanged from `docs/design-session-store-postgres-hub.md`
§4 and `docs/session-analysis.md`; the provider boundary only adds discovery and
transport, never a new payload shape.

### 4.2 Provider descriptor (the plugin artifact)

Location: `~/.config/clipvault/providers.d/<id>.json` (per host), plus
`CLIPVAULT_SESSION_PROVIDER_ID` to choose the default.

```json
{
  "id": "d2",
  "label": "d2 hub",
  "api_version": 1,
  "role": "hub",
  "store": { "engine": "postgresql", "host": "d2", "database": "clipvault" },
  "instance_ids": ["d2", "sg_d", "mac-home", "mac-work"],
  "transport": {
    "kind": "ssh-local-forward",
    "ssh_host": "d2",
    "remote_port": 9488,
    "local_port": 29488
  },
  "base_url": "http://127.0.0.1:29488"
}
```

`transport.kind` is `loopback` (forward already up), `ssh-local-forward`
(ClipVault's tunnel supervisor at `127.0.0.1:9020` ensures it), or
`direct-https` (future remote provider). `base_url` is what the router uses; the
transport block only tells ClipVault how to make `base_url` reachable.

### 4.3 Router rules

| Request | Resolved provider |
| --- | --- |
| `/trae/p/<id>/<rest>` | provider `<id>` explicitly (debug / comparison) |
| `/trae/<rest>`, no default set | first healthy provider in registry order |
| `/trae/<rest>`, default set | `CLIPVAULT_SESSION_PROVIDER_ID` |

- `WebServer.traeBackendURL(from:)` becomes `SessionProviderRouter.backendURL(for:)`.
  `CLIPVAULT_TRAE_HTTP_PORT` stays only as the fallback for the implicit
  `local` provider, preserving today's behavior on a host with no registry.
- The browser contract does not change: `web/index.html` still iframes
  `/trae/?embed=1&v=s9`; it never learns a provider id.

### 4.4 Rules that make "whoever serves PG data is the provider" enforceable

- `INV-P3`: ClipVault refuses a provider whose `/api/health` does not echo both
  `provider_id` and `store`. An HTTP shim that does not own a PostgreSQL store
  is not a provider.
- `INV-P4`: the router never hardcodes a host/port; every reachable endpoint
  comes from a descriptor. Adding a provider is adding a JSON file.
- `INV-P5`: if the default provider is unhealthy the panel shows `error`; the
  router does **not** silently fall back to another provider (mixing corpora is
  the exact defect this design removes).

### 4.5 Non-goals

| Non-goal | Reason |
| --- | --- |
| Multi-provider fan-in (merge `/api/sessions` across providers, multiplex SSE) | The hub provider already unifies every `instance_id`. Fan-in needs merge + dedupe semantics and is deferred until there is a second real corpus. |
| Streaming replication / HA | v1 buys durability + backup, not availability. Replica is a separate RPO/RTO decision. |
| Degraded/offline read on the Mac | Accepted: provider unreachable = panel down. No local session store, ever, on a client. |
| Letting a client write session rows | Only collector `INSERT`s exist; the display plane is read + pin/ack only. |
| Putting provider config in git | Descriptors are host state (SSH hosts, ports), not repo state. Only the schema + parser live in git. |

## 5. Hook change matrix

Current install path: `install.sh` (Mac store), `install_d2.sh` /
`install_remote.sh` (collectors + Quack reverse tunnel), `pi/install_pi_hook.sh`
+ `pi/install_pi_hook_remote.sh` (pi adapters). The pi `.ts` adapter itself does
not change; only the env it sources changes.

| Host | Trae hook | pi hook | Was | Becomes |
| --- | --- | --- | --- | --- |
| mac-home | `~/.trae-cn/hooks.json` | `~/.pi/agent/extensions/clipvault-session.ts` | Quack into its **own** Mac DuckDB | `CLIPVAULT_PG_DSN` -> `127.0.0.1:55432` via `ssh -L -> d2` |
| mac-work | `~/.trae-cn/hooks.json` | same | Quack `:19494` -R -> mac-work DuckDB | same DSN shape; `ssh -L -> d2` |
| d2 | `/root/.trae-cn/hooks.json` | `/root/.pi/agent/extensions/...` | Quack `127.0.0.1:19494` | `127.0.0.1:55432`, same host, no tunnel |
| sg_d | `/root/.trae-cn/hooks.json` | same | Quack `127.0.0.1:19495` | `ssh -L 55432 -> d2` (needs sg_d -> d2 key, `U-2b`) |

Env contract change (collector side):

| Old | New |
| --- | --- |
| `CLIPVAULT_QUACK_URI=quack:127.0.0.1:<port>` | `CLIPVAULT_PG_DSN=postgresql://clipvault@127.0.0.1:55432/clipvault` |
| `CLIPVAULT_QUACK_TOKEN_FILE=.../quack.token` | `CLIPVAULT_PG_PASSWORD_FILE=.../pg.password` (`chmod 600`) |
| `CLIPVAULT_QUACK_PROBE_SEC=0.25` | `CLIPVAULT_PG_CONNECT_TIMEOUT_SEC=0.25` |
| venv `duckdb==1.5.5` + quack extension | venv `psycopg[binary]` + `psycopg_pool` |

Retired everywhere: Quack extension, `:9494` listener, reverse tunnels
`clipvault-quack-d2` / `clipvault-quack-sg_d`, remote ports `19494` / `19495`,
`trae-quack.token`, the macOS LaunchAgent `com.davidmusk.clipvault-trae`, and
each Mac's local `trae/hook_events.duckdb` (kept only as a frozen rollback
anchor, never opened again).

## 6. Backup chain: d2 -> cc

```text
   d2 cron 02:30 UTC   /opt/clipvault/backup.sh
        |
        |  pg_dump -Fc -Z6 -d clipvault        (d2 -> cc via id_ed25519)
        v
   ssh cc "cat > /backup/clipvault/daily/clipvault-$(date -u +%Y%m%d).dump"
        |
        +-- pg_restore --list  | head        verify the archive is readable
        +-- ssh cc "find ... -mtime +14 -delete"   retention: 14 daily
```

- `cc` = `cc.guohuasun.com` / `203.88.122.188`; d2 already reaches it with
  `Host cc` (`IdentityFile ~/.ssh/id_ed25519`). `cc` has 154 G free.
- No Mac is in the path. A Mac being off must not gap the backup.
- `U-4` (is d2 reprovisioned?) still decides root-disk vs a dedicated volume
  for the PG data directory; the backup is the safety net either way.
- RPO = 24 h (nightly dump). If tighter is required, add WAL archiving to the
  same `cc` target as a follow-up; that is a separate decision.
- A restore drill into a throwaway database is a release gate (`RA-11`), not a
  one-time act.

## 7. Invariants

| ID | Invariant |
| --- | --- |
| `INV-1` | Exactly one writer corpus per provider: the PostgreSQL instance on d2 for provider `d2`. No Mac may run an alternative session store. |
| `INV-2` | `ts` is the capture clock; late/backfilled events keep their original `ts`. |
| `INV-3` | Dedupe by `event_id` (= `raw_hash[:32]`) and `raw_hash`; redelivery inserts zero rows. |
| `INV-4` | Hook failure is never fatal; every collector path exits 0 and spools. |
| `INV-5` | The wire timestamp string is naive-UTC `YYYY-MM-DD HH:MM:SS[.ffffff]`. |
| `INV-6` | The browser talks only to ClipVault's own origin. No page, script or iframe calls a provider or `:55432` directly. |
| `INV-7` | No payload key is silently dropped; un-promoted keys live in the drop allowlist and a new key raises an ingest alarm. |
| `INV-P1` | Session rows live in exactly one PostgreSQL per provider; ClipVault persists no session rows. |
| `INV-P2` | Every provider implements SIA v1 and echoes `provider_id` + `store` from `/api/health`. |
| `INV-P3` | Every reachable provider endpoint comes from a descriptor; the router hardcodes no host/port. |
| `INV-P4` | Unhealthy default provider = panel `error`; no silent cross-provider fallback. |
| `INV-P5` | The default provider switch is atomic and observable (router `/api/health` reports the active id). |

## 8. Migration phases

```text
Phase 0  corpus hygiene (no host change, no engine change)
   export-only: extract agent_type / agent_id / text_content,
   drop raw_json at export time; record free-delta.  [from hub doc Phase 0]

Phase 1  PostgreSQL on d2
   docker run postgres:18-alpine -p 127.0.0.1:55432:5432, durable volume
   DDL (timestamptz, raw_json gone) + COPY load + indexes
   reconcile RA-1 .. RA-4 against the frozen DuckDB snapshot

Phase 2  provider module on d2
   server.py / mine.py / ingest ported to psycopg   (no Quack, no :9494)
   SIA v1 served at d2 127.0.0.1:9488; /api/health echoes provider_id= d2

Phase 3  ClipVault becomes a client (provider plugin)
   add SessionProviderRouter + providers.d/*.json
   mac-home default -> provider d2 ; mac-work later
   RA-12: both Macs show the same sessions[] for the same window

Phase 4  collectors repointed
   d2 local ; mac-home / mac-work / sg_d via ssh -L 55432
   bootout com.davidmusk.clipvault-trae on every Mac
   remove Quack, :9494, reverse tunnels, quack.token
   RA-9 (no Mac listener on :9488), RA-5..RA-8

Phase 5  backup + retention
   d2 -> cc nightly pg_dump -Fc ; retention ; RA-11 restore drill
```

Rollback = Phase 4 back to the previous installers + the frozen DuckDB anchor;
the lossy window is "everything inserted into PostgreSQL after the freeze",
identical to the hub doc's Appendix B.

## 9. Open decisions and unknowns

| ID | Item | Needed before |
| --- | --- | --- |
| `O-1` | Aggregation: single hub provider (recommended) vs fan-in multi-provider in v1. | Phase 3 |
| `O-2` | Who owns the `ssh -L` lifecycles: ClipVault tunnel supervisor `:9020` vs launchd `ssh -L` shims. | Phase 3 |
| `O-3` | Backup retention on cc (proposed 14 daily) and whether WAL/PITR is required (proposed RPO 24 h). | Phase 5 |
| `O-4` | Does mac-home keep its `local` provider during migration, or cut straight to `d2`? | Phase 3 |
| `U-2b` | sg_d -> d2 SSH: install an `sg_d -> d2` key (preferred) vs Mac-relayed forwarding (reintroduces the Mac). | Phase 4 |
| `U-4` | Is d2 reprovisioned on a schedule? Decides root disk vs durable volume for PG data. | Phase 1 |
| `U-5` | Actual PostgreSQL size after load (estimate 1.5-3.0 GB); sets the retention threshold. | Phase 1 |
| `U-6` | `/api/mine?scope=recent&days=7` latency on PostgreSQL (DuckDB baseline 640 ms, gate <= 3x). | Phase 2 |

## 10. Reconciliation anchors

| Anchor | Condition | Exact expected result | Verification |
| --- | --- | --- | --- |
| `RA-11` | Backup is restorable off-box | `pg_restore` of the newest `cc` dump into a throwaway database succeeds; row counts match `RA-1` | restore drill |
| `RA-12` | Two clients, one corpus | mac-home and mac-work `/api/sessions` return the same `event_id` set for the same window | manual + `tests/session-provider-router.test.mjs` |
| `RA-13` | Provider health proves ownership | `/api/health` on provider `d2` reports `provider_id=d2` and `store.engine=postgresql`; router refuses it otherwise | `tests/session-provider-router.test.mjs` |

## Appendix A - Relationship to the hub design

`docs/design-session-store-postgres-hub.md` (`clipvault-session-store-postgres-hub-v1`)
already decided the PostgreSQL tab on d2, the facade contract, the wire timezone
rule, and the dedupe rules; it is retained. This document adds three things it
left open: the **write-amplification rationale**, the **d2 -> cc backup chain**
(closing `U-3`), and the **provider plugin model** for the display input API.
Where they differ, this document wins for provider/client behavior; the hub
document wins for the storage DDL and the cutover rollback window.
