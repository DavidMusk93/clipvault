#!/bin/bash
# install_pi_hook_remote.sh — wire pi sessions into ClipVault on a remote SSH host.
#
# The remote Mac-side adapter is a pi extension (pi has no hooks.json); it maps pi
# lifecycle events onto the ClipVault hook contract and pipes them through the
# host's existing `clipvault_hook.sh` (spool + Quack + SSE). Remote hosts only
# need the collector that `trae_hooks/install_remote.sh` already installs — this
# script adds the pi adapter on top of it. `install_remote.sh` calls it as part
# of a fresh host install, so pi capture is standard on every collector.
#
#   CLIPVAULT_REMOTE_SSH=sg_d bash trae_hooks/pi/install_pi_hook_remote.sh
#
# Run on Mac. Idempotent. Installs a real .ts file (Linux hosts have no repo to
# symlink into), and a pi-hooks.env that sources the Trae env then only overrides
# identity -> source=pi (instance_id stays the host's).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/trae_hooks/pi/clipvault-session.ts"
SSH_HOST="${CLIPVAULT_REMOTE_SSH:?set CLIPVAULT_REMOTE_SSH (e.g. sg_d)}"
REMOTE_ENV="${CLIPVAULT_REMOTE_HOOKS_ENV:-/root/.trae-cn/hooks_env}"
REMOTE_HOME="${CLIPVAULT_REMOTE_HOME:-/root}"
REMOTE_PI_EXT="${CLIPVAULT_REMOTE_PI_EXT:-$REMOTE_HOME/.pi/agent/extensions}"

if [ ! -f "$SRC" ]; then
  echo "missing $SRC" >&2
  exit 1
fi

echo "remote=$SSH_HOST hooks_env=$REMOTE_ENV pi_ext=$REMOTE_PI_EXT"

# Precondition: the shared Trae collector must already be installed there.
if ! ssh -o BatchMode=yes -o ConnectTimeout=12 "$SSH_HOST" \
  "test -f '$REMOTE_ENV/trae-hooks.env'"; then
  echo "FAIL: $SSH_HOST:$REMOTE_ENV/trae-hooks.env missing — run trae_hooks/install_remote.sh first." >&2
  exit 1
fi

ssh -o BatchMode=yes -o ConnectTimeout=12 "$SSH_HOST" \
  "mkdir -p '$REMOTE_ENV' '$REMOTE_PI_EXT'"

# pi-hooks.env: base install comes from the Trae env; pi only flips identity.
ssh -o BatchMode=yes "$SSH_HOST" "cat > '$REMOTE_ENV/pi-hooks.env'" <<'EOF'
# pi -> ClipVault session hook overrides. Sourced by clipvault_hook.sh.
# Base install (paths, token, spool, python, client, instance_id) comes from the
# Trae env; pi keeps the same instance_id and is told apart by source=pi.
. "$HOOKS_ENV/trae-hooks.env"
export CLIPVAULT_HOOK_SOURCE="pi"
EOF

scp -o BatchMode=yes -q "$SRC" "$SSH_HOST:$REMOTE_PI_EXT/clipvault-session.ts"

ssh -o BatchMode=yes "$SSH_HOST" \
  "chmod 600 '$REMOTE_ENV/pi-hooks.env'; chmod 644 '$REMOTE_PI_EXT/clipvault-session.ts'"

echo "installed pi adapter on $SSH_HOST"
echo "  env  $REMOTE_ENV/pi-hooks.env"
echo "  ext  $REMOTE_PI_EXT/clipvault-session.ts (real file, not a symlink)"
echo
echo "Pi picks it up on next start (or /reload). Sessions land with source=pi."
echo "Disable for one run:  CLIPVAULT_PI_SESSION_HOOK=0 pi"
