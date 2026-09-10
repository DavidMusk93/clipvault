#!/bin/bash
# restart-clipvault.sh — ONLY supported way to restart ClipVaultServer after binary/web deploy.
# NEVER: nohup ClipVaultServer &   (strips CLIPVAULT_HOME → empty App Support library)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

LABEL=com.davidmusk.clipvault
OLD_LABEL=com.davidmusk.clipflow
PLIST="${PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE_BIN="${LIVE_BIN:-$HOME/Library/Application Support/Keepsake/bin/ClipVaultServer}"
READABILITY="$REPO_ROOT/Sources/ClipVault/Archive/Resources/Readability.js"
UID_NUM="$(id -u)"
GUI="gui/${UID_NUM}"

if [ ! -f "$PLIST" ]; then
  echo "FAIL: missing LaunchAgent $PLIST" >&2
  echo "Install from repo template: $REPO_ROOT/LaunchAgents/com.davidmusk.clipvault.plist (must include CLIPVAULT_HOME)" >&2
  exit 1
fi

if ! grep -q 'KEEPSAKE_HOME\|CLIPVAULT_HOME' "$PLIST"; then
  echo "FAIL: $PLIST must set CLIPVAULT_HOME or KEEPSAKE_HOME (incident 2026-08-11)" >&2
  exit 1
fi

install_bin() {
  local src="$1"
  echo "Installing binary: $src -> $LIVE_BIN"
  mkdir -p "$(dirname "$LIVE_BIN")"
  cp "$src" "$LIVE_BIN"
  chmod +x "$LIVE_BIN"
  xattr -cr "$LIVE_BIN" 2>/dev/null || true
  codesign --force --sign - "$LIVE_BIN" >/dev/null 2>&1 || true
  if [ -f "$READABILITY" ]; then
    cp "$READABILITY" "$(dirname "$LIVE_BIN")/Readability.js"
    echo "Installed Readability.js next to binary"
  fi
}

if [ -n "${NEW_BIN:-}" ] && [ -x "$NEW_BIN" ]; then
  install_bin "$NEW_BIN"
elif [ -x "$REPO_ROOT/.build/release/ClipVaultServer" ]; then
  if [ "${INSTALL_RELEASE:-0}" = "1" ]; then
    install_bin "$REPO_ROOT/.build/release/ClipVaultServer"
  fi
fi

LIVE_HOME="$(dirname "$(dirname "$LIVE_BIN")")"
if [ -f "$REPO_ROOT/web/index.html" ]; then
  echo "Installing web/ -> $LIVE_HOME/web/"
  mkdir -p "$LIVE_HOME/web"
  rsync -a --exclude '.DS_Store' "$REPO_ROOT/web/" "$LIVE_HOME/web/"
fi

echo "Restarting $LABEL via launchctl (preserves CLIPVAULT_HOME)..."
launchctl bootout "$GUI/$OLD_LABEL" 2>/dev/null || true
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
sleep 0.5
for pid in $(ps aux | awk '/Keepsake\/bin\/(ClipFlowServer|ClipVaultServer)/ && !/awk/{print $2}'); do
  kill "$pid" 2>/dev/null || true
done
sleep 0.5
if [ -f "$HOME/Library/LaunchAgents/${LABEL}.plist" ]; then
  :
else
  cp "$REPO_ROOT/LaunchAgents/com.davidmusk.clipvault.plist" "$HOME/Library/LaunchAgents/${LABEL}.plist"
fi
launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null || true
launchctl kickstart -k "$GUI/$LABEL"
sleep 2.0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/verify-data-home.sh"
echo "restart-clipvault: OK"
