# clipvault-session (Rust)

The ClipVault session plane. Replaces the Python `trae_hooks` server with a
PostgreSQL-backed **Session API v1 (SA-v1)** facade plus a fail-open hook
collector. Architecture: `docs/design-session-backends.md`.

Two binaries:

| Binary | Role |
| --- | --- |
| `clipvault-session` | SA-v1 facade: HTTP + SSE read plane, `pin`, `ack`. Stateless w.r.t. storage; learns of new rows via `LISTEN clipvault_hook`. |
| `clipvault-hook` | Collector: stdin JSON -> spool JSONL -> `INSERT ... ON CONFLICT DO NOTHING` -> `pg_notify`. Always exits 0. Metrics events (`UsageReport`/`ContextReport`) go hot into `llm_usage`/`turn_context`. |
| `clipvault-flush` | Spool drainer: one JSONL file per event -> persistent PG connection -> batched INSERT; readiness-woken by the hook, 30s watchdog fallback. |
| `clipvault-aggregator` | Client-side fan-in: reads `backends.d/*.json`, fails over within a `corpus_id`, merges across corpora, routes writes to the primary, passes SSE through. |
| session analysis | `/api/mine` + `/api/mine/ack` (Session Analysis v2) ported to Rust in `src/mine/` (primitives, rows, analysis, run). |

## Build

```bash
cargo build --release            # host
# linux target for d2/sg_d: build on the host (cargo available there)
```

## Configuration (env)

| Var | Default | Notes |
| --- | --- | --- |
| `CLIPVAULT_PG_DSN` | — | libpq conninfo/URL; overrides the discrete vars |
| `CLIPVAULT_PG_HOST` / `_PORT` / `_DB` / `_USER` | `127.0.0.1` / `55432` / `clipvault` / `clipvault` | |
| `CLIPVAULT_PG_PASSWORD_FILE` | — | `chmod 600` file; preferred over `CLIPVAULT_PG_PASSWORD` |
| `CLIPVAULT_PG_CONNECT_TIMEOUT_SEC` | `3` | collector fail-open budget |
| `CLIPVAULT_PG_POOL` | `8` | facade pool size |
| `CLIPVAULT_BACKEND_ID` / `_CORPUS_ID` / `_ROLE` | `local` / `clipvault` / `primary` | echoed by `/api/health` (INV-B1) |
| `CLIPVAULT_TRAE_HTTP_HOST` / `_PORT` | `127.0.0.1` / `9488` | facade bind |
| `CLIPVAULT_SESSION_WEB_DIR` | — | `:`-separated dirs serving `sessions.html` + `*.mjs` |
| `CLIPVAULT_INSTANCE_ID` / `CLIPVAULT_HOOK_SOURCE` / `CLIPVAULT_HOOK_SPOOL` | `unknown` / `trae` / `/var/tmp/clipvault-hooks/spool` | collector |

## Deploy (d2, primary)

```bash
docker run -d --name clipvault-pg --restart unless-stopped \
  -e POSTGRES_USER=clipvault -e POSTGRES_DB=clipvault -e POSTGRES_PASSWORD="$(cat pg.password)" \
  -p 127.0.0.1:55432:5432 -v /data00/clipvault-pg:/var/lib/postgresql postgres:18-alpine
docker exec -i clipvault-pg psql -U clipvault -d clipvault -v ON_ERROR_STOP=1 < session/schema.sql
cp session/deploy/clipvault-session.service /etc/systemd/system/
systemctl enable --now clipvault-session
```

## Mac cutover

`session/deploy/install_macos.sh` installs the Rust collector + facade tunnel on a
Mac: hooks env -> PG on d2, wrapper execs `clipvault-hook`, a LaunchAgent forwards
`55432` (collector) and `9488` (facade) to d2, a flush LaunchAgent drains the spool,
and the old Python `com.davidmusk.clipvault-trae` / `-metrics` are booted out.
It backs up every file it overwrites (`*.bak-rust-<stamp>`).

## Status

- Done: PostgreSQL 18 on d2 (dedicated volume), SA-v1 facade, hook collector,
  `LISTEN`/`NOTIFY` SSE, `pin`, metrics hot path, spool flush, **mac-home cut
  over to d2**, **cc logical-CDC replica + replica facade**, **client fan-in
  (`clipvault-aggregator`)**, **`/api/mine` + `ack` in Rust**, **cold metrics
  ingest (`clipvault-ingest`)**, **sg_d collector**.
- Pending: mac-work collector (host offline).
