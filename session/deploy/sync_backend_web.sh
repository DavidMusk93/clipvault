#!/bin/bash
# sync_backend_web.sh — push the session-panel assets to the backends.
#
# The panel iframe is served by the backend (d2/cc), NOT by the Mac: ClipVault
# proxies /trae/* to the aggregator, which forwards the static fallback to the
# winning backend. So sessions.html AND every module it imports must exist in the
# backend web dir. A missing ES module returns 404 and aborts the whole panel
# script, which renders as an empty session panel.
#
# Both backends are pushed straight from this Mac. The old path fanned out
# d2 -> cc, but d2 cannot reach cc.guohuasun.com:22 (corp egress), so the replica
# silently kept a stale panel and only showed up after a failover. Mac reaches
# both, so push each host independently.
#
#   bash session/deploy/sync_backend_web.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D2="${CLIPVAULT_D2_SSH:-d2}"
CC="${CLIPVAULT_CC_SSH:-cc}"
WEB_DIR="${CLIPVAULT_BACKEND_WEB:-/root/clipvault/web}"

sync_host() {
  local host="$1"
  echo "=== sync web -> $host:$WEB_DIR"
  ( cd "$REPO_ROOT/trae_hooks/web" && tar czf - sessions.html ) \
    | ssh -o BatchMode=yes "$host" "mkdir -p '$WEB_DIR' && tar xzf - -C '$WEB_DIR'"
  ( cd "$REPO_ROOT/web" && tar czf - ./*.mjs ) \
    | ssh -o BatchMode=yes "$host" "tar xzf - -C '$WEB_DIR'"
  # built React app (produced by `npm run build` at deploy time)
  if [ -d "$REPO_ROOT/web/assets/session" ]; then
    ( cd "$REPO_ROOT/web" && tar czf - assets/session ) \
      | ssh -o BatchMode=yes "$host" "mkdir -p '$WEB_DIR/assets' && tar xzf - -C '$WEB_DIR'"
  else
    echo "WARN: web/assets/session missing; run: (cd web/session-app && npm run build)" >&2
  fi
  ssh -o BatchMode=yes "$host" "ls '$WEB_DIR'"
}

sync_host "$D2"
sync_host "$CC"
