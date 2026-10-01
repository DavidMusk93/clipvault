# clipvault-session (Rust)

The ClipVault session plane. Replaces the Python `trae_hooks` server with a
PostgreSQL-backed **Session API v1 (SA-v1)** facade plus a fail-open hook
collector. Architecture: `docs/design-session-backends.md`.

Two binaries:

| Binary | Role |
| --- | --- |
| `clipvault-session` | SA-v1 facade: HTTP + SSE read plane, `pin`, `ack`. Stateless w.r.t. storage; learns of new rows via `LISTEN clipvault_hook`. |
| `clipvault-hook` | Collector: stdin JSON -> spool JSONL -> `INSERT ... ON CONFLICT DO NOTHING` -> `pg_notify`. Always exits 0. |

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

## Status

- Done: PostgreSQL 18 on d2 (dedicated volume), SA-v1 facade, hook collector,
  `LISTEN`/`NOTIFY` SSE, `pin`.
- Pending: analysis (`/api/mine`, `ack`) port; metrics ingest (`clipvault-ingest`);
  the `cc` logical-CDC replica; the client-side aggregator + backend registry;
  collector installers for mac-home / mac-work / sg_d.
