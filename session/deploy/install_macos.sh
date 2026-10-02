#!/bin/bash
# install_macos.sh — cut a Mac over to the d2 session backend (Rust).
#
# Replaces the Python trae_hooks collector/facade with the Rust binaries:
#   * hooks env points at PostgreSQL on d2 (ssh -L 55432)
#   * the Trae/pi wrapper execs `clipvault-hook`
#   * a tunnel LaunchAgent forwards 55432 (collector) and 9488 (facade) to d2
#   * a flush LaunchAgent drains the spool every 60s
#   * the old Python facade + metrics LaunchAgents are booted out
#
# Idempotent. Backs up the files it overwrites. Run on the Mac:
#   bash session/deploy/install_macos.sh
#
# Env overrides: CLIPVAULT_INSTANCE_ID, CLIPVAULT_SSH_HOST (default d2),
#                CLIPVAULT_PASSWORD_FILE, CLIPVAULT_STAGE_BIN (prebuilt binaries).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:/usr/bin:/bin"

INSTANCE="${CLIPVAULT_INSTANCE_ID:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
SSH_HOST="${CLIPVAULT_SSH_HOST:-d2}"
CC_HOST="${CLIPVAULT_CC_SSH_HOST:-cc}"
HOME_DIR="$HOME"
BIN_DIR="$HOME_DIR/.clipvault/bin"
HOOKS_ENV="$HOME_DIR/.trae-cn/hooks_env"
PASSWORD_FILE="${CLIPVAULT_PASSWORD_FILE:-$HOME_DIR/.config/clipvault/pg.password}"
SPOOL="/var/tmp/clipvault-hooks/spool"
AGENTS="$HOME_DIR/Library/LaunchAgents"
STAMP="$(date +%Y%m%d-%H%M%S)"
UID_NUM="$(id -u)"

echo "instance=$INSTANCE ssh=$SSH_HOST bin=$BIN_DIR"

if [ ! -f "$PASSWORD_FILE" ]; then
  echo "FAIL: PG password file missing: $PASSWORD_FILE" >&2
  exit 1
fi

# --- binaries ---------------------------------------------------------------
mkdir -p "$BIN_DIR" "$HOOKS_ENV" "$SPOOL" "$AGENTS"
if [ -n "${CLIPVAULT_STAGE_BIN:-}" ]; then
  cp -f "$CLIPVAULT_STAGE_BIN/clipvault-hook" "$CLIPVAULT_STAGE_BIN/clipvault-flush" "$BIN_DIR/"
else
  REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ ! -x "$REPO_ROOT/session/target/release/clipvault-hook" ]; then
    echo "building session crate..."
    (cd "$REPO_ROOT/session" && cargo build --release)
  fi
  cp -f "$REPO_ROOT/session/target/release/clipvault-hook" "$BIN_DIR/"
  cp -f "$REPO_ROOT/session/target/release/clipvault-flush" "$BIN_DIR/"
  cp -f "$REPO_ROOT/session/target/release/clipvault-aggregator" "$BIN_DIR/"
  cp -f "$REPO_ROOT/session/target/release/clipvault-ingest" "$BIN_DIR/"
fi
chmod 755 "$BIN_DIR/clipvault-hook" "$BIN_DIR/clipvault-flush" "$BIN_DIR/clipvault-aggregator" "$BIN_DIR/clipvault-ingest"

# --- hooks env (PG) + wrapper ----------------------------------------------
for f in trae-hooks.env pi-hooks.env clipvault_hook.sh; do
  [ -f "$HOOKS_ENV/$f" ] && cp -a "$HOOKS_ENV/$f" "$HOOKS_ENV/$f.bak-rust-$STAMP"
done

cat > "$HOOKS_ENV/trae-hooks.env" <<EOF
# ClipVault session collector -> PostgreSQL on $SSH_HOST (Rust binary).
export CLIPVAULT_INSTANCE_ID="$INSTANCE"
export CLIPVAULT_HOOK_SOURCE="trae"
export CLIPVAULT_PG_HOST="127.0.0.1"
export CLIPVAULT_PG_PORT="55432"
export CLIPVAULT_PG_DB="clipvault"
export CLIPVAULT_PG_USER="clipvault"
export CLIPVAULT_PG_PASSWORD_FILE="$PASSWORD_FILE"
export CLIPVAULT_HOOK_SPOOL="$SPOOL"
export CLIPVAULT_HOOK_BIN="$BIN_DIR/clipvault-hook"
EOF
chmod 600 "$HOOKS_ENV/trae-hooks.env"

cat > "$HOOKS_ENV/pi-hooks.env" <<'EOF'
# pi -> ClipVault session hook overrides. Sourced by clipvault_hook.sh.
. "$HOOKS_ENV/trae-hooks.env"
export CLIPVAULT_HOOK_SOURCE="pi"
EOF
chmod 600 "$HOOKS_ENV/pi-hooks.env"

cat > "$HOOKS_ENV/clipvault_hook.sh" <<'EOF'
#!/bin/bash
# Trae/pi hook wrapper. Path must contain NO spaces (Trae runs `bash -c`).
set +e
umask 077
HOOKS_ENV="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ENV_FILE="${CLIPVAULT_HOOK_ENV:-$HOOKS_ENV/trae-hooks.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
BIN="${CLIPVAULT_HOOK_BIN:-$HOOKS_ENV/../.clipvault/bin/clipvault-hook}"
LOG_DIR="${CLIPVAULT_HOOK_LOGDIR:-/var/tmp/clipvault-hooks}"
mkdir -p "$LOG_DIR"
if [ ! -x "$BIN" ]; then
  printf '%s missing hook binary %s\n' "$(date -u +%FT%TZ)" "$BIN" >> "$LOG_DIR/wrapper.err"
  exit 0
fi
"$BIN" "$@"
exit 0
EOF
chmod 755 "$HOOKS_ENV/clipvault_hook.sh"

# --- LaunchAgents -----------------------------------------------------------
TUNNEL_PLIST="$AGENTS/com.davidmusk.clipvault-pg-tunnel.plist"
cat > "$TUNNEL_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.davidmusk.clipvault-pg-tunnel</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ControlMaster=no</string>
    <string>-o</string><string>ControlPath=none</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-L</string><string>127.0.0.1:55432:127.0.0.1:55432</string>
    <string>-L</string><string>127.0.0.1:29488:127.0.0.1:9488</string>
    <string>$SSH_HOST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>/var/tmp/clipvault-hooks/tunnel.err</string>
</dict></plist>
EOF

FLUSH_PLIST="$AGENTS/com.davidmusk.clipvault-flush.plist"
cat > "$FLUSH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.davidmusk.clipvault-flush</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/clipvault-flush</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>CLIPVAULT_PG_HOST</key><string>127.0.0.1</string>
    <key>CLIPVAULT_PG_PORT</key><string>55432</string>
    <key>CLIPVAULT_PG_DB</key><string>clipvault</string>
    <key>CLIPVAULT_PG_USER</key><string>clipvault</string>
    <key>CLIPVAULT_PG_PASSWORD_FILE</key><string>$PASSWORD_FILE</string>
    <key>CLIPVAULT_HOOK_SPOOL</key><string>$SPOOL</string>
    <key>CLIPVAULT_FLUSH_WAKE</key><string>127.0.0.1:19499</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
EOF

# Replica tunnel + backend registry + aggregator. The aggregator owns :9488,
# which is what ClipVault already proxies /trae/* to; the backends live on
# 29488 (d2) and 29489 (cc).
CC_TUNNEL_PLIST="$AGENTS/com.davidmusk.clipvault-cc-tunnel.plist"
cat > "$CC_TUNNEL_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.davidmusk.clipvault-cc-tunnel</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ControlMaster=no</string>
    <string>-o</string><string>ControlPath=none</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-L</string><string>127.0.0.1:29489:127.0.0.1:9488</string>
    <string>$CC_HOST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>/var/tmp/clipvault-hooks/cc-tunnel.err</string>
</dict></plist>
EOF

BACKENDS_DIR="$HOME_DIR/.config/clipvault/backends.d"
mkdir -p "$BACKENDS_DIR"
cat > "$BACKENDS_DIR/d2.json" <<EOF
{ "id": "d2", "label": "d2 primary", "api_version": 1, "corpus_id": "clipvault", "role": "primary", "priority": 100, "base_url": "http://127.0.0.1:29488" }
EOF
cat > "$BACKENDS_DIR/cc.json" <<EOF
{ "id": "cc", "label": "cc replica", "api_version": 1, "corpus_id": "clipvault", "role": "replica", "priority": 10, "base_url": "http://127.0.0.1:29489" }
EOF

AGG_PLIST="$AGENTS/com.davidmusk.clipvault-aggregator.plist"
cat > "$AGG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.davidmusk.clipvault-aggregator</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/clipvault-aggregator</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>CLIPVAULT_BACKENDS_DIR</key><string>$BACKENDS_DIR</string>
    <key>CLIPVAULT_AGG_HTTP_PORT</key><string>9488</string>
    <key>CLIPVAULT_AGG_DEFAULT_CORPUS</key><string>clipvault</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>/var/tmp/clipvault-hooks/aggregator.err</string>
</dict></plist>
EOF

INGEST_PLIST="$AGENTS/com.davidmusk.clipvault-ingest.plist"
cat > "$INGEST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.davidmusk.clipvault-ingest</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/clipvault-ingest</string>
    <string>--since</string><string>30</string>
    <string>--quiet</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>CLIPVAULT_PG_HOST</key><string>127.0.0.1</string>
    <key>CLIPVAULT_PG_PORT</key><string>55432</string>
    <key>CLIPVAULT_PG_DB</key><string>clipvault</string>
    <key>CLIPVAULT_PG_USER</key><string>clipvault</string>
    <key>CLIPVAULT_PG_PASSWORD_FILE</key><string>$PASSWORD_FILE</string>
    <key>CLIPVAULT_INSTANCE_ID</key><string>$INSTANCE</string>
    <key>CLIPVAULT_HOOK_SOURCE</key><string>pi</string>
    <key>CLIPVAULT_PI_SESSIONS</key><string>$HOME_DIR/.pi/agent/sessions</string>
  </dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/var/tmp/clipvault-hooks/ingest.err</string>
</dict></plist>
EOF

# --- swap services ----------------------------------------------------------
for label in com.davidmusk.clipvault-trae com.davidmusk.clipvault-metrics; do
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
done
sleep 1
for label in com.davidmusk.clipvault-pg-tunnel com.davidmusk.clipvault-cc-tunnel com.davidmusk.clipvault-flush com.davidmusk.clipvault-aggregator com.davidmusk.clipvault-ingest; do
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
done
launchctl bootstrap "gui/$UID_NUM" "$CC_TUNNEL_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$TUNNEL_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$FLUSH_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$AGG_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$INGEST_PLIST"

echo "waiting for the tunnel..."
for _ in $(seq 1 20); do
  if curl -fsS --noproxy '*' -m 2 http://127.0.0.1:9488/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
echo "--- facade health (via tunnel -> d2) ---"
curl -sS --noproxy '*' -m 4 http://127.0.0.1:9488/api/health || echo "UNREACHABLE"
echo
echo "--- collector probe ---"
CLIPVAULT_HOOK_ENV="$HOOKS_ENV/trae-hooks.env" \
  "$HOOKS_ENV/clipvault_hook.sh" --event Notification <<< \
  '{"session_id":"install-probe","hook_event_name":"Notification","notification_type":"idle_prompt","message":"install probe"}'
echo "probe exit=$?"
echo "done. backups: $HOOKS_ENV/*.bak-rust-$STAMP"
