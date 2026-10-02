#!/bin/bash
# sync_backend_web.sh — push the session-panel assets to the backends.
#
# The panel iframe is served by the backend (d2/cc), NOT by the Mac: ClipVault
# proxies /trae/* to the aggregator, which forwards the static fallback to the
# winning backend. So sessions.html AND every module it imports must exist in the
# backend web dir. A missing ES module returns 404 and aborts the whole panel
# script, which renders as an empty session panel.
#
#   bash session/deploy/sync_backend_web.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D2="${CLIPVAULT_D2_SSH:-d2}"
CC="${CLIPVAULT_CC_SSH:-cc}"
WEB_DIR="${CLIPVAULT_BACKEND_WEB:-/root/clipvault/web}"

echo "sync web -> $D2:$WEB_DIR (+ $CC)"
( cd "$REPO_ROOT/trae_hooks/web" && tar czf - sessions.html ) \
  | ssh -o BatchMode=yes "$D2" "mkdir -p '$WEB_DIR' && tar xzf - -C '$WEB_DIR'"
( cd "$REPO_ROOT/web" && tar czf - ./*.mjs ) \
  | ssh -o BatchMode=yes "$D2" "tar xzf - -C '$WEB_DIR'"
# fan out to the replica
ssh -o BatchMode=yes "$D2" "tar czf - -C '$WEB_DIR' . | ssh -o BatchMode=yes $CC 'mkdir -p $WEB_DIR && tar xzf - -C $WEB_DIR'"
echo "--- $D2:$WEB_DIR ---"
ssh -o BatchMode=yes "$D2" "ls '$WEB_DIR'"
