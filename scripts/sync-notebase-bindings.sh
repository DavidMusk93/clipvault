#!/usr/bin/env bash
# Copy UniFFI bindings from the notebase checkout into this package.
#
#   ./scripts/sync-notebase-bindings.sh [path-to-notebase]
#
# Generated files are vendored so building ClipVault does not require cargo.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

NOTEBASE="${1:-$HOME/dev/notebase}"
OUT="$(mktemp -d)"
"$NOTEBASE/scripts/gen-bindings.sh" swift "$OUT" >/dev/null
mkdir -p Sources/NotebaseFFI Sources/CNotebase
cp "$OUT/notebase_ffi.swift" Sources/NotebaseFFI/notebase_ffi.swift
cp "$OUT/notebase_ffiFFI.h" Sources/CNotebase/notebase_ffiFFI.h
cat > Sources/CNotebase/module.modulemap <<'MODULEMAP'
module notebase_ffiFFI {
    header "notebase_ffiFFI.h"
    export *
}
MODULEMAP
echo "synced bindings from $NOTEBASE (build the static lib with: cd $NOTEBASE && cargo build --release -p notebase-ffi)"
