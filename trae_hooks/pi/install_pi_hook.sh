#!/bin/bash
# install_pi_hook.sh — wire pi sessions into the ClipVault Trae session store.
#
# pi has no hooks.json; the adapter is a pi extension that maps pi lifecycle
# events onto the ClipVault hook contract and pipes them through the existing
# Trae wrapper. Run the Trae install first (trae_hooks/install.sh) so the
# wrapper, venv, token, and LaunchAgent store already exist.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/trae_hooks/pi/clipvault-session.ts"
HOOKS_ENV="$HOME/.trae-cn/hooks_env"
PI_EXT_DIR="$HOME/.pi/agent/extensions"
PI_ENV="$HOOKS_ENV/pi-hooks.env"
PI_EXT="$PI_EXT_DIR/clipvault-session.ts"

if [ ! -f "$HOOKS_ENV/trae-hooks.env" ]; then
  echo "FAIL: $HOOKS_ENV/trae-hooks.env missing — run trae_hooks/install.sh first." >&2
  exit 1
fi

mkdir -p "$PI_EXT_DIR"

cat > "$PI_ENV" <<'EOF'
# pi -> ClipVault session hook overrides. Sourced by clipvault_hook.sh.
# Base install (paths, token, spool, python, client) comes from the Trae env;
# only identity differs so pi sessions are labelled distinctly from Trae.
. "$HOOKS_ENV/trae-hooks.env"
export CLIPVAULT_INSTANCE_ID="${CLIPVAULT_PI_INSTANCE:-pi-mac}"
export CLIPVAULT_HOOK_SOURCE="pi"
EOF
chmod 600 "$PI_ENV"

ln -sfn "$SRC" "$PI_EXT"

echo "wrote  $PI_ENV"
echo "linked $PI_EXT -> $SRC"
echo
echo "Enable in pi: restart pi, or run /reload if the extension was already discovered."
echo "pi sessions then land as source=pi, instance_id=\${CLIPVAULT_PI_INSTANCE:-pi-mac}."
echo "Disable for one run:  CLIPVAULT_PI_SESSION_HOOK=0 pi"
