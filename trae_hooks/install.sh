#!/bin/bash
# Install ClipVault Trae hook store: venv, token, LaunchAgent, hooks.json, wrapper.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/trae_hooks"
HOME_USER="${HOME}"
CLIPVAULT_HOME="${CLIPVAULT_HOME:-${KEEPSAKE_HOME:-$HOME_USER/Documents/ClipFlow}}"
KEEP_SUPPORT="$HOME_USER/Library/Application Support/Keepsake"
VENV="$KEEP_SUPPORT/trae-hooks-venv"
# Trae executes hook commands via unquoted bash -c. Path MUST be space-free.
HOOKS_ENV="$HOME_USER/.trae-cn/hooks_env"
TOKEN_FILE="$CLIPVAULT_HOME/config/trae-quack.token"
ENV_FILE="$HOOKS_ENV/trae-hooks.env"
WRAPPER_DST="$HOOKS_ENV/clipvault_hook.sh"
PLIST_DST="$HOME_USER/Library/LaunchAgents/com.davidmusk.clipvault-trae.plist"
HOOKS_JSON_DST="$HOME_USER/.trae-cn/hooks.json"
SPOOL="/var/tmp/clipvault-hooks/spool"
LABEL=com.davidmusk.clipvault-trae
UID_NUM="$(id -u)"
GUI="gui/${UID_NUM}"

mkdir -p "$KEEP_SUPPORT/bin" "$KEEP_SUPPORT/config" "$KEEP_SUPPORT/logs" \
  "$CLIPVAULT_HOME/config" "$CLIPVAULT_HOME/trae" "$SPOOL" "$HOOKS_ENV"

if [ ! -x "$VENV/bin/python" ]; then
  echo "creating venv $VENV"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.13 "$VENV"
  else
    python3 -m venv "$VENV"
  fi
fi

if ! "$VENV/bin/python" -c 'import duckdb,sys; assert duckdb.__version__>="1.5.5"' 2>/dev/null; then
  echo "installing duckdb==1.5.5 into venv"
  PROXY_ARGS=()
  if nc -z -w 1 127.0.0.1 2080 2>/dev/null; then
    export ALL_PROXY="socks5h://127.0.0.1:2080"
    export HTTPS_PROXY="$ALL_PROXY"
    export HTTP_PROXY="$ALL_PROXY"
  elif nc -z -w 1 sys-proxy-rd-relay.byted.org 8118 2>/dev/null; then
    export ALL_PROXY="http://sys-proxy-rd-relay.byted.org:8118"
    export HTTPS_PROXY="$ALL_PROXY"
    export HTTP_PROXY="$ALL_PROXY"
  fi
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$VENV/bin/python" "duckdb==1.5.5"
  else
    "$VENV/bin/python" -m pip install "duckdb==1.5.5"
  fi
fi

if [ ! -f "$TOKEN_FILE" ]; then
  echo "generating quack token at $TOKEN_FILE"
  openssl rand -hex 24 > "$TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"

ln -sfn "$VENV" "$HOOKS_ENV/venv"
install -m 644 "$HOOKS_DIR/hook_client.py" "$HOOKS_ENV/hook_client.py"
install -m 644 "$HOOKS_DIR/metrics.py" "$HOOKS_ENV/metrics.py"
install -m 644 "$HOOKS_DIR/pi_session_ingest.py" "$HOOKS_ENV/pi_session_ingest.py"
install -m 644 "$HOOKS_DIR/row.py" "$HOOKS_ENV/row.py"
install -m 755 "$HOOKS_DIR/pi_session_ingest.sh" "$HOOKS_ENV/pi_session_ingest.sh"
install -m 755 "$HOOKS_DIR/clipvault_hook.sh" "$WRAPPER_DST"

cat > "$ENV_FILE" <<EOF
export CLIPVAULT_HOME="$CLIPVAULT_HOME"
export KEEPSAKE_HOME="$CLIPVAULT_HOME"
export CLIPVAULT_INSTANCE_ID="${CLIPVAULT_INSTANCE_ID:-mac-work}"
export CLIPVAULT_QUACK_URI="quack:127.0.0.1:9494"
export CLIPVAULT_QUACK_TOKEN_FILE="$TOKEN_FILE"
export CLIPVAULT_HOOK_SPOOL="$SPOOL"
export CLIPVAULT_HOOK_PYTHON="$HOOKS_ENV/venv/bin/python"
export CLIPVAULT_HOOK_CLIENT="$HOOKS_ENV/hook_client.py"
EOF
chmod 600 "$ENV_FILE"

# LaunchAgent: rewrite home-specific paths from template.
python3 - <<PY
from pathlib import Path
src = Path("$HOOKS_DIR/com.davidmusk.clipvault-trae.plist").read_text()
src = src.replace("/Users/bytedance", "$HOME_USER")
src = src.replace("/Users/bytedance/Documents/trae_projects/recallfs/projects/clipvault", "$REPO_ROOT")
src = src.replace("/Users/bytedance/Documents/trae_projects/recallfs/projects/ClipView", "$REPO_ROOT")
src = src.replace("/Users/bytedance/Documents/ClipFlow", "$CLIPVAULT_HOME")
Path("$PLIST_DST").write_text(src)
print("wrote $PLIST_DST")
PY

python3 - <<PY
from pathlib import Path
src = Path("$HOOKS_DIR/hooks.json").read_text()
src = src.replace("/Users/bytedance/.trae-cn/hooks_env/clipvault_hook.sh", "$WRAPPER_DST")
src = src.replace("/Users/bytedance", "$HOME_USER")
Path("$HOOKS_JSON_DST").parent.mkdir(parents=True, exist_ok=True)
Path("$HOOKS_JSON_DST").write_text(src)
print("wrote $HOOKS_JSON_DST")
PY

echo "bootstrapping $LABEL"
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
sleep 0.3
launchctl bootstrap "$GUI" "$PLIST_DST"
sleep 1.2

# Metrics backfill agent: pi session JSONL -> llm_usage / turn_context.
METRICS_LABEL=com.davidmusk.clipvault-metrics
METRICS_PLIST_DST="$HOME_USER/Library/LaunchAgents/$METRICS_LABEL.plist"
python3 - <<PY
from pathlib import Path
src = Path("$HOOKS_DIR/com.davidmusk.clipvault-metrics.plist").read_text()
src = src.replace("/Users/bytedance", "$HOME_USER")
Path("$METRICS_PLIST_DST").write_text(src)
print("wrote $METRICS_PLIST_DST")
PY
launchctl bootout "$GUI/$METRICS_LABEL" 2>/dev/null || true
sleep 0.3
launchctl bootstrap "$GUI" "$METRICS_PLIST_DST" || true

echo "--- probe ---"
curl -fsS --max-time 3 "http://127.0.0.1:9488/api/health" || {
  echo "HTTP not ready yet; last logs:" >&2
  tail -n 40 "$KEEP_SUPPORT/logs/clipvault-trae.err.log" 2>/dev/null || true
  tail -n 40 "$KEEP_SUPPORT/logs/clipvault-trae.out.log" 2>/dev/null || true
  exit 1
}
echo
echo "install ok"
echo "UI:   ClipVault 顶栏「会话」→ http://127.0.0.1:8080/#sessions （:9488 仅进程口）"
echo "hook: $WRAPPER_DST"
echo "json: $HOOKS_JSON_DST"
echo "Next: Trae 设置 > Hooks > 启用全局 + 本地自动运行，然后完全退出 Trae 再开。"
