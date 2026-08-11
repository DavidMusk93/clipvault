#!/bin/bash
# deploy-server.sh — build release + install binary + LaunchAgent restart + verify.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
echo "swift build -c release..."
swift build -c release --product ClipFlowServer
export INSTALL_RELEASE=1
"$REPO_ROOT/scripts/restart-clipflow.sh"
