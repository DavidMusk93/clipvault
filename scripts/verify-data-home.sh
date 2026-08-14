#!/bin/bash
# verify-data-home.sh — refuse "looks fine" when ClipVault is on the wrong library.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

DOC_HOME="${CLIPVAULT_HOME:-${KEEPSAKE_HOME:-$HOME/Documents/ClipFlow}}"
AS_HOME="$HOME/Library/Application Support/Keepsake"
LABEL="${LAUNCH_LABEL:-com.davidmusk.clipflow}"
MIN_ITEMS="${MIN_ITEMS:-10}"
MIN_DB_BYTES="${MIN_DB_BYTES:-65536}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m%s\033[0m\n' "$*"; }

echo "=== ClipVault data-home verify ==="

# 1) Process + env
PIDS=$(ps aux | awk '/Keepsake\/bin\/ClipFlowServer/ && !/awk/{print $2}')
if [ -z "${PIDS:-}" ]; then
  red "FAIL: ClipFlowServer not running"
  exit 1
fi
echo "pids: $PIDS"

if launchctl print "gui/$(id -u)/$LABEL" >/tmp/cv_launch_print.txt 2>/dev/null; then
  # Do not strip spaces: mac-home home is ".../Application Support/Keepsake".
  ENV_HOME=$(awk -F'=> ' '/KEEPSAKE_HOME|CLIPVAULT_HOME/{print $2}' /tmp/cv_launch_print.txt | head -1 | sed 's/[[:space:]]*$//')
  echo "launchd env home: ${ENV_HOME:-<missing>}"
  if [ -z "${ENV_HOME:-}" ]; then
    red "FAIL: LaunchAgent missing KEEPSAKE_HOME/CLIPVAULT_HOME"
    exit 1
  fi
else
  echo "warn: launchctl print $LABEL failed (may be manual start)"
fi

db_size() {
  local f="$1/clipflow.db"
  if [ -f "$f" ]; then stat -f%z "$f"; else echo 0; fi
}

DOC_SZ=$(db_size "$HOME/Documents/ClipFlow")
AS_SZ=$(db_size "$AS_HOME")
echo "Documents/ClipFlow db bytes: $DOC_SZ"
echo "AppSupport/Keepsake db bytes: $AS_SZ"

# 2) HTTP + item sample
HTTP=$(curl -sS -m 3 -o /tmp/cv_clips_sample.json -w '%{http_code}' 'http://127.0.0.1:8080/api/clips?limit=5' || echo 000)
if [ "$HTTP" != "200" ]; then
  red "FAIL: API HTTP $HTTP"
  exit 1
fi

# 3) Prefer sqlite count on expected home (LaunchAgent home)
EXPECT_HOME="$HOME/Documents/ClipFlow"
if [ -n "${ENV_HOME:-}" ]; then EXPECT_HOME="$ENV_HOME"; fi
DB="$EXPECT_HOME/clipflow.db"
if [ ! -f "$DB" ]; then
  red "FAIL: expected db missing: $DB"
  exit 1
fi
if ! command -v sqlite3 >/dev/null; then
  red "FAIL: sqlite3 not installed"
  exit 1
fi
ITEMS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM clipboard_items;")
ALIVE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM clipboard_items WHERE deleted_at IS NULL;")
echo "sqlite items=$ITEMS alive=$ALIVE db=$DB"

if [ "$ITEMS" -lt "$MIN_ITEMS" ]; then
  # Wrong-home detector
  if [ "$DOC_SZ" -ge "$MIN_DB_BYTES" ] && [ "$EXPECT_HOME" != "$HOME/Documents/ClipFlow" ]; then
    red "FAIL: only $ITEMS items but Documents library is ${DOC_SZ}B — likely wrong home"
    exit 1
  fi
  if [ "$AS_SZ" -ge "$MIN_DB_BYTES" ] && [ "$EXPECT_HOME" = "$HOME/Documents/ClipFlow" ] && [ "$DOC_SZ" -lt "$MIN_DB_BYTES" ]; then
    red "FAIL: Documents tiny but AppSupport has ${AS_SZ}B — check KEEPSAKE_HOME"
    exit 1
  fi
  if [ "$DOC_SZ" -ge "$MIN_DB_BYTES" ] && [ "$ITEMS" -lt "$MIN_ITEMS" ]; then
    # db large but count low? possible corruption
    red "FAIL: items=$ITEMS < MIN_ITEMS=$MIN_ITEMS (db ${DOC_SZ}B)"
    exit 1
  fi
fi

# 4) API should not look empty when sqlite has corpus
PAGE=$(/usr/bin/python3 -c 'import json;print(len(json.load(open("/tmp/cv_clips_sample.json")).get("items") or []))')
if [ "$ITEMS" -ge "$MIN_ITEMS" ] && [ "$PAGE" -eq 0 ]; then
  red "FAIL: sqlite has $ITEMS items but API returned 0 — wrong process/home serving :8080"
  exit 1
fi

ok "OK data home sane: items=$ITEMS alive=$ALIVE home=$EXPECT_HOME api_page=$PAGE"
