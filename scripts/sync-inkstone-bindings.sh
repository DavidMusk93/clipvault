#!/usr/bin/env bash
# Copy UniFFI bindings from the inkstone checkout into this package.
#
#   ./scripts/sync-inkstone-bindings.sh [path-to-inkstone]
#
# Generated files are vendored so building ClipVault does not require cargo.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

INKSTONE="${1:-$HOME/dev/inkstone}"
OUT="$(mktemp -d)"
"$INKSTONE/scripts/gen-bindings.sh" swift "$OUT" >/dev/null
mkdir -p Sources/InkstoneFFI Sources/CInkstone
cp "$OUT/inkstone_ffi.swift" Sources/InkstoneFFI/inkstone_ffi.swift
cp "$OUT/inkstone_ffiFFI.h" Sources/CInkstone/inkstone_ffiFFI.h
cat > Sources/CInkstone/module.modulemap <<'MODULEMAP'
module inkstone_ffiFFI {
    header "inkstone_ffiFFI.h"
    export *
}
MODULEMAP
echo "synced bindings from $INKSTONE (build the static lib with: cd $INKSTONE && cargo build --release -p inkstone-ffi)"
