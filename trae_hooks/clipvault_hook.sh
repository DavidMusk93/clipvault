#!/bin/bash
# Trae hook wrapper. Path must contain NO spaces — Trae runs `bash -c $command`
# without quoting, so `Application Support` becomes two argv tokens (exit 127).
set +e
umask 077

HOOKS_ENV="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ENV_FILE="${CLIPVAULT_HOOK_ENV:-$HOOKS_ENV/trae-hooks.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

VENV_PY="${CLIPVAULT_HOOK_PYTHON:-$HOOKS_ENV/venv/bin/python}"
CLIENT="${CLIPVAULT_HOOK_CLIENT:-$HOOKS_ENV/hook_client.py}"

EVENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event)
      EVENT="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

LOG_DIR="${CLIPVAULT_HOOK_LOGDIR:-/var/tmp/clipvault-hooks}"
mkdir -p "$LOG_DIR"

if [ ! -x "$VENV_PY" ]; then
  printf '%s missing python %s\n' "$(date -u +%FT%TZ)" "$VENV_PY" >> "$LOG_DIR/wrapper.err"
  exit 0
fi
if [ ! -f "$CLIENT" ]; then
  printf '%s missing client %s\n' "$(date -u +%FT%TZ)" "$CLIENT" >> "$LOG_DIR/wrapper.err"
  exit 0
fi

"$VENV_PY" "$CLIENT" --event "$EVENT"
exit 0
