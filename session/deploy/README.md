# session deploy

Topology and runbook for the Rust session plane. Architecture:
`docs/design-session-backends.md`.

```text
   Macs (backends.d fan-in)                       d2 (primary)            cc (replica)
   ------------------------                       ------------            ------------
   ClipVault --/trae/*--> aggregator              PG18 55432              PG18 5432
                              |                    ^                       ^
                     ssh -L 9488 -> d2             |  logical CDC          |
                              v                    |  (pgoutput)           |
                       clipvault-session  <--------+    d2 --ssh -R 15432--> cc
                              ^                    ^
   collectors: clipvault-hook -> ssh -L 55432 -> d2:55432
```

## Files

| File | Where |
| --- | --- |
| `install_macos.sh` | run on a Mac: Rust collector + facade tunnel + flush LaunchAgents |
| `clipvault-session.service` | d2 primary facade (systemd) |
| `clipvault-cdc-tunnel.service` | d2: reverse tunnel exposing d2 PG to cc's loopback |
| `clipvault-session-cc.service` | cc replica facade (systemd) |

## Primary (d2)

```bash
# PostgreSQL 18 on a dedicated volume, loopback-only
docker run -d --name clipvault-pg --restart unless-stopped \
  -e POSTGRES_USER=clipvault -e POSTGRES_DB=clipvault -e POSTGRES_PASSWORD="$(cat /root/.config/clipvault/pg.password)" \
  -e POSTGRES_INITDB_ARGS='--data-checksums' \
  -p 127.0.0.1:55432:5432 -v /data00/clipvault-pg:/var/lib/postgresql postgres:18-alpine
docker exec -i clipvault-pg psql -U clipvault -d clipvault -v ON_ERROR_STOP=1 < session/schema.sql
cp session/deploy/clipvault-session.service /etc/systemd/system/ && systemctl enable --now clipvault-session
```

## Replica (cc) + logical CDC

cc already runs PostgreSQL 18 natively (`postgresql@18-main`, loopback `:5432`);
no Docker there.

```bash
# 1. d2 publisher
docker exec clipvault-pg psql -U clipvault -d clipvault -c "ALTER SYSTEM SET wal_level='logical'"
docker exec clipvault-pg psql -U clipvault -d clipvault -c "ALTER SYSTEM SET max_slot_wal_keep_size='4GB'"
docker restart clipvault-pg
docker exec clipvault-pg psql -U clipvault -d clipvault -c \
  "CREATE ROLE repl LOGIN REPLICATION PASSWORD '<pw>'"   # idempotent: guard on pg_roles
docker exec clipvault-pg psql -U clipvault -d clipvault \
  -c "CREATE PUBLICATION clipvault_pub FOR ALL TABLES"
# allow cc's subscriber to SELECT the published tables
for s in "GRANT CONNECT ON DATABASE clipvault TO repl" \
         "GRANT USAGE ON SCHEMA public TO repl" \
         "GRANT SELECT ON ALL TABLES IN SCHEMA public TO repl" \
         "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO repl"; do
  docker exec clipvault-pg psql -U clipvault -d clipvault -c "$s"; done

# 2. d2 -> cc reverse tunnel (logical replication is a pull; cc cannot reach d2)
#    cc's 127.0.0.1:15432 -> d2's 127.0.0.1:55432
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519_cc   # on d2; authorized on cc
cp session/deploy/clipvault-cdc-tunnel.service /etc/systemd/system/ && systemctl enable --now clipvault-cdc-tunnel

# 3. cc subscriber
su - postgres -c "psql -c \"CREATE ROLE clipvault LOGIN PASSWORD '<pw>'\""
su - postgres -c "createdb -O clipvault clipvault"
PGPASSWORD='<pw>' psql -h 127.0.0.1 -U clipvault -d clipvault -f session/schema.sql
su - postgres -c "psql -d clipvault -c \"CREATE SUBSCRIPTION clipvault_sub \
  CONNECTION 'host=127.0.0.1 port=15432 dbname=clipvault user=repl password=<pw>' \
  PUBLICATION clipvault_pub WITH (copy_data=true, streaming=true)\""

# 4. cc replica facade
cp session/deploy/clipvault-session-cc.service /etc/systemd/system/ && systemctl enable --now clipvault-session
```

Verify:

```bash
# on d2
docker exec clipvault-pg psql -U clipvault -d clipvault -tAc \
  "SELECT slot_name, active, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) FROM pg_replication_slots"
# on cc
curl -sS http://127.0.0.1:9488/api/health   # role=replica
```

## Guardrails

- The primary is the only writer. A replica facade returns `role=replica`; pin/ack
  must be routed to the primary by the client aggregator.
- A stalled slot is bounded by `max_slot_wal_keep_size`; alert on
  `pg_stat_subscription` lag or `active=false`.
- If the replica falls past the WAL keep limit, re-seed:
  `DROP SUBSCRIPTION clipvault_sub; CREATE SUBSCRIPTION ... copy_data=true`.
