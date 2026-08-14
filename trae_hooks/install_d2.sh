#!/bin/bash
# Run on Mac: bash trae_hooks/install_d2.sh
# Installs space-free ClipVault hook runtime on ssh d2. Does not open Mac Quack to LAN.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/trae_hooks"
SSH_HOST="${CLIPVAULT_D2_SSH:-d2}"
REMOTE_ENV="/root/.trae-cn/hooks_env"
TOKEN_SRC="${CLIPVAULT_QUACK_TOKEN_FILE:-$HOME/Documents/ClipFlow/config/trae-quack.token}"

if [ ! -f "$TOKEN_SRC" ]; then
  echo "missing token $TOKEN_SRC" >&2
  exit 1
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" "mkdir -p '$REMOTE_ENV' /var/tmp/clipvault-hooks/spool /etc/systemd/system"

scp -o BatchMode=yes \
  "$HOOKS_DIR/clipvault_hook.sh" \
  "$HOOKS_DIR/hook_client.py" \
  "$HOOKS_DIR/row.py" \
  "$HOOKS_DIR/spool_flush.py" \
  "$HOOKS_DIR/hooks.d2.json" \
  "$HOOKS_DIR/clipvault-hook-flush.service" \
  "$SSH_HOST:$REMOTE_ENV/"

# token: never echo
scp -o BatchMode=yes "$TOKEN_SRC" "$SSH_HOST:$REMOTE_ENV/quack.token"
ssh -o BatchMode=yes "$SSH_HOST" "chmod 600 '$REMOTE_ENV/quack.token' && chmod 755 '$REMOTE_ENV/clipvault_hook.sh'"

ssh -o BatchMode=yes "$SSH_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
ENV=/root/.trae-cn/hooks_env
VENV="$ENV/venv"
export PATH="/root/.local/bin:/usr/bin:/bin"

if [ ! -x "$VENV/bin/python" ]; then
  uv venv --python 3.13 "$VENV"
fi
if ! "$VENV/bin/python" -c 'import duckdb; assert duckdb.__version__>="1.5.5"' 2>/dev/null; then
  if nc -z -w 1 127.0.0.1 2080 2>/dev/null; then
    export ALL_PROXY=socks5h://127.0.0.1:2080 HTTPS_PROXY=socks5h://127.0.0.1:2080 HTTP_PROXY=socks5h://127.0.0.1:2080
  elif nc -z -w 1 sys-proxy-rd-relay.byted.org 8118 2>/dev/null; then
    export ALL_PROXY=http://sys-proxy-rd-relay.byted.org:8118
    export HTTPS_PROXY=$ALL_PROXY HTTP_PROXY=$ALL_PROXY
  fi
  uv pip install --python "$VENV/bin/python" "duckdb==1.5.5"
fi

# Load quack once so hook later is offline-capable.
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

cat > "$ENV/trae-hooks.env" <<'EOF'
export CLIPVAULT_INSTANCE_ID="d2"
export CLIPVAULT_HOOK_SOURCE="trae"
export CLIPVAULT_QUACK_URI="quack:127.0.0.1:19494"
export CLIPVAULT_QUACK_TOKEN_FILE="/root/.trae-cn/hooks_env/quack.token"
export CLIPVAULT_HOOK_SPOOL="/var/tmp/clipvault-hooks/spool"
export CLIPVAULT_HOOK_PYTHON="/root/.trae-cn/hooks_env/venv/bin/python"
export CLIPVAULT_HOOK_CLIENT="/root/.trae-cn/hooks_env/hook_client.py"
export CLIPVAULT_QUACK_PROBE_SEC="0.25"
EOF
chmod 600 "$ENV/trae-hooks.env"

if [ -f /root/.trae-cn/hooks.json ] && [ ! -f /root/.trae-cn/hooks.json.bak-trae-sm-20260814 ]; then
  cp -a /root/.trae-cn/hooks.json /root/.trae-cn/hooks.json.bak-trae-sm-20260814
fi
cp "$ENV/hooks.d2.json" /root/.trae-cn/hooks.json

cp "$ENV/clipvault-hook-flush.service" /etc/systemd/system/clipvault-hook-flush.service
systemctl daemon-reload
systemctl enable --now clipvault-hook-flush.service
REMOTE

echo "d2 hook files installed. Enable Mac tunnel next if not running."
