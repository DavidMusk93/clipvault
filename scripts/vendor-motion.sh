#!/usr/bin/env bash
# Bundle Motion (motion.dev) for ClipVault sheet transitions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/web/assets/motion.js"
WORKDIR="$(mktemp -d /tmp/clipvault-motion.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if nc -z 127.0.0.1 2080 2>/dev/null; then
  export ALL_PROXY=socks5h://127.0.0.1:2080
  export HTTPS_PROXY="$ALL_PROXY" HTTP_PROXY="$ALL_PROXY"
  export all_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" http_proxy="$ALL_PROXY"
fi

cd "$WORKDIR"
npm init -y >/dev/null
npm install --no-fund --no-audit motion@11 esbuild
cp "$ROOT/web/assets/motion-entry.js" "$WORKDIR/entry.js"
./node_modules/.bin/esbuild entry.js \
  --bundle \
  --format=iife \
  --minify \
  --platform=browser \
  --define:process.env.NODE_ENV='"production"' \
  --outfile="$OUT"
echo "wrote $OUT"
