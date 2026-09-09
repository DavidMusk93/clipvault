#!/bin/bash
# Install ClipVault Trae *collector* on a remote SSH host.
# Does NOT start DuckDB server there. Writes go to Mac Quack via ssh -R.
#
#   CLIPVAULT_REMOTE_SSH=sg_d CLIPVAULT_INSTANCE_ID=sg_d \
#   CLIPVAULT_REMOTE_QUACK_PORT=19495 bash trae_hooks/install_remote.sh
#
# Run on Mac. Token is scp'd, never echoed.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/trae_hooks"
SSH_HOST="${CLIPVAULT_REMOTE_SSH:?set CLIPVAULT_REMOTE_SSH (e.g. sg_d)}"
INSTANCE="${CLIPVAULT_INSTANCE_ID:?set CLIPVAULT_INSTANCE_ID (e.g. sg_d)}"
RPORT="${CLIPVAULT_REMOTE_QUACK_PORT:?set CLIPVAULT_REMOTE_QUACK_PORT (e.g. 19495)}"
REMOTE_ENV="${CLIPVAULT_REMOTE_HOOKS_ENV:-/root/.trae-cn/hooks_env}"
TOKEN_SRC="${CLIPVAULT_QUACK_TOKEN_FILE:-$HOME/Documents/ClipFlow/config/trae-quack.token}"
REMOTE_PY="${CLIPVAULT_REMOTE_PYTHON:-}"

if [ ! -f "$TOKEN_SRC" ]; then
  echo "missing token $TOKEN_SRC" >&2
  exit 1
fi

echo "remote=$SSH_HOST instance=$INSTANCE quack=127.0.0.1:$RPORT env=$REMOTE_ENV"

ssh -o BatchMode=yes -o ConnectTimeout=12 "$SSH_HOST" \
  "mkdir -p '$REMOTE_ENV' /var/tmp/clipvault-hooks/spool /etc/systemd/system"

scp -o BatchMode=yes \
  "$HOOKS_DIR/clipvault_hook.sh" \
  "$HOOKS_DIR/hook_client.py" \
  "$HOOKS_DIR/row.py" \
  "$HOOKS_DIR/spool_flush.py" \
  "$HOOKS_DIR/clipvault-hook-flush.service" \
  "$SSH_HOST:$REMOTE_ENV/"

scp -o BatchMode=yes "$TOKEN_SRC" "$SSH_HOST:$REMOTE_ENV/quack.token"
ssh -o BatchMode=yes "$SSH_HOST" "chmod 600 '$REMOTE_ENV/quack.token' && chmod 755 '$REMOTE_ENV/clipvault_hook.sh'"

# Generate hooks.json with this host's wrapper path (no spaces).
python3 - "$HOOKS_DIR/hooks.json" "$REMOTE_ENV/clipvault_hook.sh" <<'PY' | ssh -o BatchMode=yes "$SSH_HOST" "cat > '$REMOTE_ENV/hooks.json'"
import json, sys
from pathlib import Path
src = json.loads(Path(sys.argv[1]).read_text())
wrapper = sys.argv[2]
def walk(obj):
    if isinstance(obj, dict):
        if "command" in obj and isinstance(obj["command"], str) and "clipvault_hook.sh" in obj["command"]:
            ev = ""
            if "--event" in obj["command"]:
                ev = obj["command"].split("--event", 1)[1].strip()
            obj["command"] = f"{wrapper} --event {ev}".rstrip()
        for v in obj.values():
            walk(v)
    elif isinstance(obj, list):
        for v in obj:
            walk(v)
walk(src)
json.dump(src, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

ssh -o BatchMode=yes "$SSH_HOST" "INSTANCE='$INSTANCE' RPORT='$RPORT' REMOTE_ENV='$REMOTE_ENV' REMOTE_PY='$REMOTE_PY' bash -s" <<'REMOTE'
set -euo pipefail
ENV="$REMOTE_ENV"
VENV="$ENV/venv"
export PATH="/root/.local/bin:/usr/bin:/bin:$PATH"

pick_py() {
  if [ -n "${REMOTE_PY}" ] && [ -x "$REMOTE_PY" ]; then
    echo "$REMOTE_PY"
    return
  fi
  if command -v uv >/dev/null 2>&1; then
    echo "uv"
    return
  fi
  for c in /root/.local/bin/python3.13 /root/.local/bin/python3.12 /root/.local/bin/python3.11 python3.11 python3.12 python3.13; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
      echo "$c"
      return
    fi
  done
  echo "need python>=3.11 (system 3.7 cannot install duckdb 1.5.5)" >&2
  exit 1
}

PYBIN="$(pick_py)"
if [ ! -x "$VENV/bin/python" ]; then
  echo "creating venv with $PYBIN"
  if [ "$PYBIN" = "uv" ]; then
    uv venv --python 3.13 "$VENV" || uv venv --python 3.11 "$VENV"
  else
    "$PYBIN" -m venv "$VENV"
  fi
fi

if ! "$VENV/bin/python" -c 'import duckdb,sys; assert duckdb.__version__>="1.5.5"' 2>/dev/null; then
  echo "installing duckdb==1.5.5"
  if nc -z -w 1 127.0.0.1 2080 2>/dev/null; then
    export ALL_PROXY=socks5h://127.0.0.1:2080 HTTPS_PROXY=socks5h://127.0.0.1:2080 HTTP_PROXY=socks5h://127.0.0.1:2080
  elif nc -z -w 1 sys-proxy-rd-relay.byted.org 8118 2>/dev/null; then
    export ALL_PROXY=http://sys-proxy-rd-relay.byted.org:8118
    export HTTPS_PROXY=$ALL_PROXY HTTP_PROXY=$ALL_PROXY
  fi
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$VENV/bin/python" "duckdb==1.5.5"
  else
    "$VENV/bin/python" -m pip install --upgrade pip
    "$VENV/bin/python" -m pip install "duckdb==1.5.5"
  fi
fi

"$VENV/bin/python" - <<'PY'
import duckdb
from pathlib import Path
con = duckdb.connect(":memory:")
ext = Path.home() / ".duckdb/extensions/v1.5.5/linux_amd64/quack.duckdb_extension"
try:
    if ext.is_file():
        con.execute(f"LOAD '{ext}'")
    else:
        try:
            con.execute("INSTALL quack FROM core")
        except Exception:
            con.execute("INSTALL quack FROM core_nightly")
        con.execute("LOAD quack")
    print("quack_ok")
finally:
    con.close()
PY

umask 077
cat > "$ENV/trae-hooks.env" <<EOF
CLIPVAULT_INSTANCE_ID=${INSTANCE}
CLIPVAULT_HOOK_SOURCE=trae
CLIPVAULT_QUACK_URI=quack:127.0.0.1:${RPORT}
CLIPVAULT_QUACK_TOKEN_FILE=${ENV}/quack.token
CLIPVAULT_HOOK_SPOOL=/var/tmp/clipvault-hooks/spool
CLIPVAULT_HOOK_PYTHON=${ENV}/venv/bin/python
CLIPVAULT_HOOK_CLIENT=${ENV}/hook_client.py
CLIPVAULT_QUACK_PROBE_SEC=0.25
EOF
chmod 600 "$ENV/trae-hooks.env"

if [ -f /root/.trae-cn/hooks.json ] && [ ! -f /root/.trae-cn/hooks.json.bak-clipvault ]; then
  cp -a /root/.trae-cn/hooks.json /root/.trae-cn/hooks.json.bak-clipvault
fi
cp "$ENV/hooks.json" /root/.trae-cn/hooks.json

cp "$ENV/clipvault-hook-flush.service" /etc/systemd/system/clipvault-hook-flush.service
systemctl daemon-reload
systemctl enable --now clipvault-hook-flush.service
echo "remote collector installed instance=${INSTANCE} quack=127.0.0.1:${RPORT}"
echo "Next: reverse tunnel + hard-restart Trae on this host."
REMOTE

echo
echo "Mac next:"
echo "  1) tunnel  ${SSH_HOST}:127.0.0.1:${RPORT}  →  127.0.0.1:9494"
echo "     curl -sS -X POST http://127.0.0.1:9020/api/tunnel/clipvault-quack-${INSTANCE}/start"
echo "     # or: ssh -fN -o ExitOnForwardFailure=yes -o BatchMode=yes -R 127.0.0.1:${RPORT}:127.0.0.1:9494 ${SSH_HOST}"
echo "  2) hard-restart Trae on ${SSH_HOST} so it loads hooks.json"
echo "docs: docs/trae-hooks.md"
