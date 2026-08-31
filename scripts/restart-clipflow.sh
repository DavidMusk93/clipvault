#!/bin/bash
# restart-clipflow.sh — ONLY supported way to restart ClipFlowServer after binary/web deploy.
# NEVER: nohup ClipFlowServer &   (strips KEEPSAKE_HOME → empty App Support library)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

LABEL=com.davidmusk.clipflow
PLIST="${PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE_BIN="${LIVE_BIN:-$HOME/Library/Application Support/Keepsake/bin/ClipFlowServer}"
UID_NUM="$(id -u)"
GUI="gui/${UID_NUM}"

if [ ! -f "$PLIST" ]; then
  echo "FAIL: missing LaunchAgent $PLIST" >&2
  echo "Install from repo template: $REPO_ROOT/com.davidmusk.clipflow.plist (must include KEEPSAKE_HOME)" >&2
  exit 1
fi

# Require env in plist
if ! grep -q 'KEEPSAKE_HOME\|CLIPVAULT_HOME' "$PLIST"; then
  echo "FAIL: $PLIST must set KEEPSAKE_HOME or CLIPVAULT_HOME (incident 2026-08-11)" >&2
  exit 1
fi

# Optional: install new binary if NEW_BIN set or .build/release present
if [ -n "${NEW_BIN:-}" ] && [ -x "$NEW_BIN" ]; then
  echo "Installing binary: $NEW_BIN -> $LIVE_BIN"
  mkdir -p "$(dirname "$LIVE_BIN")"
  cp "$NEW_BIN" "$LIVE_BIN"
  chmod +x "$LIVE_BIN"
  if [ -f "$REPO_ROOT/ClipFlow/Resources/Readability.js" ]; then
    cp "$REPO_ROOT/ClipFlow/Resources/Readability.js" "$(dirname "$LIVE_BIN")/Readability.js"
  fi
elif [ -x "$REPO_ROOT/.build/release/ClipFlowServer" ]; then
  if [ "${INSTALL_RELEASE:-0}" = "1" ]; then
    echo "Installing .build/release/ClipFlowServer -> $LIVE_BIN"
    mkdir -p "$(dirname "$LIVE_BIN")"
    cp "$REPO_ROOT/.build/release/ClipFlowServer" "$LIVE_BIN"
    chmod +x "$LIVE_BIN"
    if [ -f "$REPO_ROOT/ClipFlow/Resources/Readability.js" ]; then
      cp "$REPO_ROOT/ClipFlow/Resources/Readability.js" "$(dirname "$LIVE_BIN")/Readability.js"
      echo "Installed Readability.js next to binary"
    fi
  fi
fi

echo "Restarting $LABEL via launchctl (preserves KEEPSAKE_HOME)..."
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
sleep 0.5
# ensure no orphan bare processes
for pid in $(ps aux | awk '/Keepsake\/bin\/ClipFlowServer/ && !/awk/{print $2}'); do
  kill "$pid" 2>/dev/null || true
done
sleep 0.5
launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null || true
# bootstrap loads the job but often does not spawn it; kickstart is the reliable start.
launchctl kickstart -k "$GUI/$LABEL"
sleep 1.2

# Post-condition
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/verify-data-home.sh"
echo "restart-clipflow: OK"
