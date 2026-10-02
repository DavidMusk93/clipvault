#!/bin/bash
# install_linux_collector.sh — wire a Linux host into the d2 session backend (Rust).
#
# The host must reach d2 over ssh; the collector writes to d2 PostgreSQL through
# an `ssh -L 55432` tunnel. Binaries, the PG password, and the env are pulled
# from d2 (which owns the build).
#
#   CLIPVAULT_REMOTE_SSH=sg_d CLIPVAULT_INSTANCE_ID=sg_d \
#     bash session/deploy/install_linux_collector.sh
#
# Idempotent. Run from the Mac.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${CLIPVAULT_REMOTE_SSH:?set CLIPVAULT_REMOTE_SSH (e.g. sg_d)}"
INSTANCE="${CLIPVAULT_INSTANCE_ID:-$HOST}"
D2="${CLIPVAULT_D2_SSH:-d2}"
ENV_DIR="${CLIPVAULT_REMOTE_HOOKS_ENV:-/root/.trae-cn/hooks_env}"
PI_EXT_DIR="${CLIPVAULT_REMOTE_PI_EXT:-/root/.pi/agent/extensions}"

echo "host=$HOST instance=$INSTANCE d2=$D2 env=$ENV_DIR"

# The pi adapter is a repo file; push it after the host is prepared.
PI_TS="$REPO_ROOT/trae_hooks/pi/clipvault-session.ts"

ssh -o BatchMode=yes -o ConnectTimeout=12 "$HOST" "INSTANCE='$INSTANCE' D2='$D2' ENV_DIR='$ENV_DIR' PI_EXT_DIR='$PI_EXT_DIR' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
mkdir -p "$ENV_DIR" /root/clipvault/bin /root/.config/clipvault /var/tmp/clipvault-hooks/spool "$PI_EXT_DIR"

# 1. binaries + password from d2 (the host can reach d2)
for f in clipvault-hook clipvault-flush; do
  scp -q -o BatchMode=yes "d2:/root/clipvault/bin/$f" "/root/clipvault/bin/$f"
done
scp -q -o BatchMode=yes "d2:/root/.config/clipvault/pg.password" "/root/.config/clipvault/pg.password"
chmod 755 /root/clipvault/bin/clipvault-hook /root/clipvault/bin/clipvault-flush
chmod 600 /root/.config/clipvault/pg.password

# 2. hook env + wrapper
cat > "$ENV_DIR/trae-hooks.env" <<EOF
export CLIPVAULT_INSTANCE_ID="$INSTANCE"
export CLIPVAULT_HOOK_SOURCE="trae"
export CLIPVAULT_PG_HOST="127.0.0.1"
export CLIPVAULT_PG_PORT="55432"
export CLIPVAULT_PG_DB="clipvault"
export CLIPVAULT_PG_USER="clipvault"
export CLIPVAULT_PG_PASSWORD_FILE="/root/.config/clipvault/pg.password"
export CLIPVAULT_HOOK_SPOOL="/var/tmp/clipvault-hooks/spool"
export CLIPVAULT_HOOK_BIN="/root/clipvault/bin/clipvault-hook"
export CLIPVAULT_FLUSH_WAKE="127.0.0.1:19499"
EOF
chmod 600 "$ENV_DIR/trae-hooks.env"

cat > "$ENV_DIR/pi-hooks.env" <<'EOF'
. "$HOOKS_ENV/trae-hooks.env"
export CLIPVAULT_HOOK_SOURCE="pi"
EOF
chmod 600 "$ENV_DIR/pi-hooks.env"

cat > "$ENV_DIR/clipvault_hook.sh" <<'EOF'
#!/bin/bash
# Trae/pi hook wrapper. Path must contain NO spaces.
set +e
umask 077
HOOKS_ENV="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ENV_FILE="${CLIPVAULT_HOOK_ENV:-$HOOKS_ENV/trae-hooks.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
BIN="${CLIPVAULT_HOOK_BIN:-/root/clipvault/bin/clipvault-hook}"
LOG_DIR="${CLIPVAULT_HOOK_LOGDIR:-/var/tmp/clipvault-hooks}"
mkdir -p "$LOG_DIR"
if [ ! -x "$BIN" ]; then
  printf '%s missing hook binary %s\n' "$(date -u +%FT%TZ)" "$BIN" >> "$LOG_DIR/wrapper.err"
  exit 0
fi
"$BIN" "$@"
exit 0
EOF
chmod 755 "$ENV_DIR/clipvault_hook.sh"

# 3. systemd: PG tunnel + flush daemon
cat > /etc/systemd/system/clipvault-pg-tunnel.service <<EOF
[Unit]
Description=ClipVault PostgreSQL tunnel to d2
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 127.0.0.1:55432:127.0.0.1:55432 $D2
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/clipvault-flush.service <<'EOF'
[Unit]
Description=ClipVault session spool writer
After=network-online.target clipvault-pg-tunnel.service
Wants=network-online.target
[Service]
Type=simple
Environment=CLIPVAULT_PG_HOST=127.0.0.1
Environment=CLIPVAULT_PG_PORT=55432
Environment=CLIPVAULT_PG_DB=clipvault
Environment=CLIPVAULT_PG_USER=clipvault
Environment=CLIPVAULT_PG_PASSWORD_FILE=/root/.config/clipvault/pg.password
Environment=CLIPVAULT_HOOK_SPOOL=/var/tmp/clipvault-hooks/spool
Environment=CLIPVAULT_FLUSH_WAKE=127.0.0.1:19499
ExecStart=/root/clipvault/bin/clipvault-flush
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable --now clipvault-hook-flush.service 2>/dev/null || true
systemctl enable --now clipvault-pg-tunnel.service clipvault-flush.service
sleep 2
echo "tunnel=$(systemctl is-active clipvault-pg-tunnel) flush=$(systemctl is-active clipvault-flush)"
REMOTE

# 4. pi adapter (repo file)
scp -q -o BatchMode=yes "$PI_TS" "$HOST:$PI_EXT_DIR/clipvault-session.ts"
ssh -o BatchMode=yes "$HOST" "chmod 644 '$PI_EXT_DIR/clipvault-session.ts'"

# 5. probe
echo "--- collector probe ---"
ssh -o BatchMode=yes "$HOST" "bash '$ENV_DIR/clipvault_hook.sh' --event Notification" <<< \
  '{"session_id":"install-probe","hook_event_name":"Notification","notification_type":"idle_prompt","message":"linux install probe"}'
echo "done."
