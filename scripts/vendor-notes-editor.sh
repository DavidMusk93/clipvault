#!/usr/bin/env bash
# Rebuild web/assets/notes-editor from npm (@milkdown/crepe).
# Network: SOCKS5 127.0.0.1:2080 if present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/web/assets/notes-editor"
WORKDIR="$(mktemp -d /tmp/clipvault-notes-ed.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if nc -z 127.0.0.1 2080 2>/dev/null; then
  export ALL_PROXY=socks5h://127.0.0.1:2080
  export HTTPS_PROXY="$ALL_PROXY" HTTP_PROXY="$ALL_PROXY"
  export all_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" http_proxy="$ALL_PROXY"
fi

cd "$WORKDIR"
npm init -y >/dev/null
npm install --no-fund --no-audit @milkdown/crepe @milkdown/utils esbuild
cp "$OUT/entry.js" "$WORKDIR/entry.js"
cat > "$WORKDIR/theme.css" <<'CSS'
@import '@milkdown/crepe/theme/common/prosemirror.css';
@import '@milkdown/crepe/theme/common/reset.css';
@import '@milkdown/crepe/theme/common/code-mirror.css';
@import '@milkdown/crepe/theme/common/cursor.css';
@import '@milkdown/crepe/theme/common/image-block.css';
@import '@milkdown/crepe/theme/common/link-tooltip.css';
@import '@milkdown/crepe/theme/common/list-item.css';
@import '@milkdown/crepe/theme/common/placeholder.css';
@import '@milkdown/crepe/theme/common/toolbar.css';
@import '@milkdown/crepe/theme/common/table.css';
@import '@milkdown/crepe/theme/common/top-bar.css';
@import '@milkdown/crepe/theme/classic.css';
CSS
./node_modules/.bin/esbuild entry.js --bundle --format=iife --minify --outfile="$OUT/notes-editor.js"
./node_modules/.bin/esbuild theme.css --bundle --outfile="$OUT/notes-editor.css"
echo "wrote $OUT/notes-editor.js $OUT/notes-editor.css"
