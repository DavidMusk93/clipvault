#!/usr/bin/env bash
# Rebuild web/assets/notes-editor/notes-editor.js from CodeMirror 6 + marked.
# Network: SOCKS5 127.0.0.1:2080 if present. Does not overwrite notes-editor.css.
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
npm install --no-fund --no-audit \
  @codemirror/view@6 \
  @codemirror/state@6 \
  @codemirror/commands@6 \
  @codemirror/language@6 \
  @codemirror/lang-markdown@6 \
  marked@9.1.6 \
  dompurify@3.1.6 \
  esbuild

mkdir -p "$WORKDIR/web/assets/notes-editor"
cp "$OUT/entry.js" "$WORKDIR/web/assets/notes-editor/entry.js"
cp "$ROOT/web/markdown-render.mjs" "$WORKDIR/web/markdown-render.mjs"

./node_modules/.bin/esbuild \
  web/assets/notes-editor/entry.js \
  --bundle \
  --format=iife \
  --minify \
  --platform=browser \
  --outfile="$OUT/notes-editor.js"

echo "wrote $OUT/notes-editor.js"
