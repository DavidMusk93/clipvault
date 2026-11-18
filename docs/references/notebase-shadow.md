# notebase shadow (mac-home first)

ClipVault's note storage is unchanged. A **second copy** of every saved note is
mirrored into the notebase engine so the engine runs on real data before it owns
the write path. See `Sources/ClipVault/Notebase/NotebaseShadow.swift`.

## What it is

| | |
| --- | --- |
| vault | `$CLIPVAULT_HOME/notebase.db` (override: `CLIPVAULT_NOTEBASE_PATH`) |
| switch | `CLIPVAULT_NOTEBASE_SHADOW=1` in the LaunchAgent; off = every call is a no-op |
| write | after a successful `/api/compose`, on a utility queue, markdown only |
| delete | soft-delete in ClipVault removes the note from the shadow |
| cost | one serial queue, no locks on the request path, errors logged once |
| failure mode | shadow stale/missing, ClipVault unaffected |

## Endpoints (404 unless the switch is on)

```text
GET /api/notebase/stats           counts, oplog bytes, errors, path
GET /api/notebase/probe?q=<text>  search the engine's index; proves the mirror is live
```

## Why a projection, not the CRDT

The editor still writes ClipVault's own storage, so the mirror takes the same
markdown ClipVault stores. That means the shadow vault can be deleted and
rebuilt at any time (`cargo run -p notebase-store --example migrate-clipvault`),
which is exactly the property a shadow should have.

At cutover the direction flips: the engine becomes the writer and the markdown
projection becomes the export — that is a separate, deliberate step.

## Building

```bash
(cd ../notebase && cargo build --release -p notebase-ffi)   # static lib + FFI
./scripts/sync-notebase-bindings.sh ../notebase             # vendored bindings
swift build                                                  # links libnotebase_ffi.a
```

`Package.swift` links the static library only when `libnotebase_ffi.a` exists;
otherwise `NOTEBASE` is not defined and the shadow compiles to no-ops.
