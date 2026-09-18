#!/bin/bash
# collector_selfcheck.sh — verify a ClipVault collector is actually working.
#
# `systemctl is-active` only proves the unit is up. It does NOT catch the two
# failures that silently stranded d2 for a month:
#   * trae-hooks.env written as `export KEY=value` — systemd EnvironmentFile
#     ignores those lines, so the flush service ran with an empty env and
#     crashed on the Mac-side default token path on every tick;
#   * a missing Mac-side reverse tunnel.
#
# Run on the host, or from the Mac:
#   ssh <host> 'bash <hooks_env>/collector_selfcheck.sh'
#
# Exit 0 = healthy (warnings allowed), 1 = a hard failure.
set -uo pipefail

ENV_FILE="${1:-${CLIPVAULT_HOOK_ENV:-/root/.trae-cn/hooks_env/trae-hooks.env}}"
UNIT="${CLIPVAULT_FLUSH_UNIT:-clipvault-hook-flush.service}"
fail=0

echo "ClipVault collector self-check ($ENV_FILE)"

if [ ! -f "$ENV_FILE" ]; then
  echo "  FAIL: $ENV_FILE missing"
  exit 1
fi

# systemd EnvironmentFile is KEY=value only; `export KEY=` lines are dropped.
if grep -qE '^[[:space:]]*export[[:space:]]' "$ENV_FILE"; then
  echo "  FAIL: $ENV_FILE uses 'export' — systemd ignores those lines (write KEY=value)"
  fail=1
fi

SPOOL="$(sed -n 's/^CLIPVAULT_HOOK_SPOOL=//p' "$ENV_FILE" | tail -1)"
SPOOL="${SPOOL:-/var/tmp/clipvault-hooks/spool}"
QUACK="$(sed -n 's/^CLIPVAULT_QUACK_URI=//p' "$ENV_FILE" | tail -1)"

# The running service must actually see the env — not just "be active".
if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
  PID="$(systemctl show "$UNIT" -p MainPID --value 2>/dev/null)"
  if [ -n "$PID" ] && [ "$PID" != "0" ] \
    && tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep -q '^CLIPVAULT_QUACK_URI='; then
    echo "  ok: $UNIT active and sees CLIPVAULT_* env (pid $PID)"
  else
    echo "  FAIL: $UNIT active but its process has no CLIPVAULT_* env — systemctl restart $UNIT"
    fail=1
  fi
else
  echo "  FAIL: $UNIT not active"
  fail=1
fi

# Tunnel is started from the Mac side, so warn only.
if [ -n "$QUACK" ]; then
  hp="${QUACK#quack:}"
  host="${hp%:*}"; port="${hp##*:}"
  if nc -z -w 2 "${host:-127.0.0.1}" "${port:-9494}" 2>/dev/null; then
    echo "  ok: quack tunnel reachable at $QUACK"
  else
    echo "  WARN: $QUACK not reachable — start the Mac-side reverse tunnel (docs/trae-hooks.md)"
  fi
fi

pending=0; flushed=0
[ -d "$SPOOL" ] && pending="$(find "$SPOOL" -maxdepth 1 -name 'hooks-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
[ -d "$SPOOL/done" ] && flushed="$(find "$SPOOL/done" -maxdepth 1 -name 'hooks-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
echo "  spool: $pending pending file(s), $flushed flushed"
if [ "$pending" -gt 0 ] && [ "$flushed" -eq 0 ]; then
  echo "  WARN: pending spool never drained — check $SPOOL/flush.err and journalctl -u $UNIT"
fi

if [ "$fail" -ne 0 ]; then
  echo "collector self-check: FAIL"
  exit 1
fi
echo "collector self-check: OK"
