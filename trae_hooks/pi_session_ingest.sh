#!/bin/bash
# Periodic metrics backfill: pi session JSONL -> llm_usage / turn_context.
# Uses the same env file as the hook client so Quack uri/token/instance line up.
# Safe to run on a timer: rows are keyed by <session>:<message.timestamp> and
# upserted, so re-ingesting the same JSONL is a no-op.
set -uo pipefail

HOOKS_ENV="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ENV_FILE="${CLIPVAULT_HOOK_ENV:-$HOOKS_ENV/trae-hooks.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

PY="${CLIPVAULT_HOOK_PYTHON:-$HOOKS_ENV/venv/bin/python}"
INGEST="${CLIPVAULT_INGEST_CLIENT:-$HOOKS_ENV/pi_session_ingest.py}"

if [ ! -x "$PY" ]; then
  echo "pi_session_ingest.sh: missing python $PY" >&2
  exit 1
fi
if [ ! -f "$INGEST" ]; then
  echo "pi_session_ingest.sh: missing client $INGEST" >&2
  exit 1
fi

exec "$PY" "$INGEST" "$@"
