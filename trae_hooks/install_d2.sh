#!/bin/bash
# d2 preset for install_remote.sh
set -euo pipefail
export CLIPVAULT_REMOTE_SSH="${CLIPVAULT_REMOTE_SSH:-d2}"
export CLIPVAULT_INSTANCE_ID="${CLIPVAULT_INSTANCE_ID:-d2}"
export CLIPVAULT_REMOTE_QUACK_PORT="${CLIPVAULT_REMOTE_QUACK_PORT:-19494}"
exec "$(cd "$(dirname "$0")" && pwd)/install_remote.sh"
