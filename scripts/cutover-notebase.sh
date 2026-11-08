#!/usr/bin/env bash
# Flip ClipVault's note write path onto the notebase engine (or back).
#
#   ./scripts/cutover-notebase.sh on      # engine becomes primary
#   ./scripts/cutover-notebase.sh off     # ClipVault's own tables become primary again
#   ./scripts/cutover-notebase.sh status  # what the running server thinks
#
# Pre-flight for "on":
#   1. the vault must exist (seed: notebase's migrate-clipvault example)
#   2. take a VACUUM INTO safety snapshot of the vault first
#   3. flip the LaunchAgent env, restart, audit drift, smoke-test a save
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

LABEL=com.davidmusk.clipvault
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
HOME_DIR="${CLIPVAULT_HOME:-$HOME/Library/Application Support/Keepsake}"
VAULT="${CLIPVAULT_NOTEBASE_PATH:-$HOME_DIR/notebase.db}"
NOTEBASE="${NOTEBASE_REPO:-$HOME/dev/notebase}"
API="http://127.0.0.1:8080"

plist_env() {
  python3 - "$PLIST" "$1" "$2" <<'PY'
import plistlib, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
d = plistlib.load(open(path, "rb"))
env = d.setdefault("EnvironmentVariables", {})
if value == "-":
    env.pop(key, None)
else:
    env[key] = value
plistlib.dump(d, open(path, "wb"))
print(f"{key}={value}")
PY
}

restart() {
  INSTALL_RELEASE=1 ./scripts/restart-clipvault.sh >/tmp/clipvault-restart.log 2>&1 || true
  for _ in $(seq 1 40); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/api/items?limit=1")" = "200" ]; then return 0; fi
    sleep 2
  done
  echo "server did not come back; see /tmp/clipvault-restart.log" >&2
  tail -5 /tmp/clipvault-restart.log >&2
  return 1
}

case "${1:-status}" in
  status)
    curl -s "$API/api/notebase/stats" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("stats", d), ensure_ascii=False, indent=1))' 2>/dev/null || echo "engine endpoints unavailable"
    echo "--- plist env"
    python3 - "$PLIST" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
for k, v in sorted(d.get("EnvironmentVariables", {}).items()):
    if "NOTEBASE" in k:
        print(f"{k}={v}")
PY
    ;;
  on)
    if [ ! -f "$VAULT" ]; then
      echo "[1/4] seeding vault from clipflow.db"
      ( cd "$NOTEBASE" && cargo run --release -q -p notebase-store --example migrate-clipvault -- \
          --db "$HOME_DIR/clipflow.db" --out "$VAULT" )
    fi
    echo "[1/4] safety snapshot of the vault"
    SNAP="$HOME_DIR/notebase-before-cutover-$(date +%Y%m%d-%H%M%S).db"
    sqlite3 "$VAULT" "VACUUM INTO '$SNAP';"
    echo "      $SNAP ($(stat -f%z "$SNAP") bytes)"
    echo "[2/4] flipping CLIPVAULT_NOTEBASE_PRIMARY=1"
    plist_env CLIPVAULT_NOTEBASE_PRIMARY 1
    plist_env CLIPVAULT_NOTEBASE_SHADOW 1
    echo "[3/4] restart"
    restart
    echo "[4/4] audit"
    curl -s "$API/api/notebase/audit?limit=500" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"checked={d[\"checked\"]} drift={d[\"drift\"]} primary={d[\"enginePrimary\"]}"); [print("  DRIFT", s["id"]) for s in d["samples"][:3]]'
    ;;
  off)
    echo "flipping CLIPVAULT_NOTEBASE_PRIMARY=0 (shadow stays on)"
    plist_env CLIPVAULT_NOTEBASE_PRIMARY 0
    restart
    ;;
  *)
    echo "usage: $0 on|off|status" >&2
    exit 2
    ;;
esac
