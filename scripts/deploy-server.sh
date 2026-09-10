#!/bin/bash
# deploy-server.sh — build release + install binary + LaunchAgent restart + verify.
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
echo "swift build -c release..."
swift build -c release --product ClipFlowServer
echo "cargo build -p clipvault-http (HTTP/2 one-hop)..."
(
  cd "$REPO_ROOT/http-front"
  if nc -z 127.0.0.1 2080 2>/dev/null; then
    export ALL_PROXY=socks5h://127.0.0.1:2080 HTTPS_PROXY=socks5h://127.0.0.1:2080 HTTP_PROXY=socks5h://127.0.0.1:2080
    export all_proxy="$ALL_PROXY" https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
  fi
  cargo build --release
)
LIVE_BIN="${LIVE_BIN:-$HOME/Library/Application Support/Keepsake/bin/ClipFlowServer}"
mkdir -p "$(dirname "$LIVE_BIN")"
HTTP_BIN="$(dirname "$LIVE_BIN")/clipvault-http"
cp "$REPO_ROOT/http-front/target/release/clipvault-http" "$HTTP_BIN"
chmod +x "$HTTP_BIN"
xattr -cr "$HTTP_BIN" 2>/dev/null || true
codesign --force --sign - "$HTTP_BIN" >/dev/null 2>&1 || true
export INSTALL_RELEASE=1
"$REPO_ROOT/scripts/restart-clipflow.sh"
