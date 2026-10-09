#!/bin/bash
# verify-single-instance.sh — one owner per data home.
#
# Fails when more than one ClipVaultServer / clipvault-http is alive, or when the
# flock owner recorded in run/server.lock is not the live server pid. The
# 2026-10-09 incident ran two servers: the second unlinked + rebound
# run/http.sock and its clipvault-http looped on `bind :8080 Address already in
# use` -> exit 2. Run after any restart / deploy.
set -euo pipefail

DATA_HOME="${CLIPVAULT_HOME:-${KEEPSAKE_HOME:-$HOME/Library/Application Support/Keepsake}}"
FAIL=0

SERVER_PIDS="$( { pgrep -f "Keepsake/bin/ClipVaultServer" || true; pgrep -f "Keepsake/bin/ClipFlowServer" || true; } | sort -u )"
FRONT_PIDS="$(pgrep -f "Keepsake/bin/clipvault-http" || true)"
SERVER_N="$(printf '%s\n' "$SERVER_PIDS" | grep -c . || true)"
FRONT_N="$(printf '%s\n' "$FRONT_PIDS" | grep -c . || true)"

if [ "$SERVER_N" -ne 1 ]; then
  echo "FAIL: expected 1 ClipVaultServer, found $SERVER_N: $(echo $SERVER_PIDS)" >&2
  FAIL=1
fi
if [ "$FRONT_N" -ne 1 ]; then
  echo "FAIL: expected 1 clipvault-http, found $FRONT_N: $(echo $FRONT_PIDS)" >&2
  FAIL=1
fi

LOCK="$DATA_HOME/run/server.lock"
if [ "$SERVER_N" -eq 1 ]; then
  OWNER="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$LOCK" 2>/dev/null | head -1 || true)"
  if [ "$OWNER" != "$SERVER_PIDS" ]; then
    echo "FAIL: lock owner pid=${OWNER:-none} != live server pid=$SERVER_PIDS" >&2
    FAIL=1
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "verify-single-instance: OK (server=$(echo $SERVER_PIDS) front=$(echo $FRONT_PIDS))"
fi
exit "$FAIL"
