# inkstone shadow (mac-home first)

ClipVault's note storage is unchanged. A **second copy** of every saved note is
mirrored into the inkstone engine so the engine runs on real data before it owns
the write path. See `Sources/ClipVault/Inkstone/InkstoneShadow.swift`.

## What it is

| | |
| --- | --- |
| vault | `$CLIPVAULT_HOME/inkstone.db` (override: `CLIPVAULT_INKSTONE_PATH`) |
| switch | `CLIPVAULT_INKSTONE_SHADOW=1` in the LaunchAgent; off = every call is a no-op |
| write | after a successful `/api/compose`, on a utility queue, markdown only |
| delete | soft-delete in ClipVault removes the note from the shadow |
| cost | one serial queue, no locks on the request path, errors logged once |
| failure mode | shadow stale/missing, ClipVault unaffected |

## Endpoints (404 unless the switch is on)

```text
GET /api/inkstone/stats           counts, oplog bytes, errors, path
GET /api/inkstone/probe?q=<text>  search the engine's index; proves the mirror is live
```

## Why a projection, not the CRDT

The editor still writes ClipVault's own storage, so the mirror takes the same
markdown ClipVault stores. That means the shadow vault can be deleted and
rebuilt at any time (`cargo run -p inkstone-store --example migrate-clipvault`),
which is exactly the property a shadow should have.

At cutover the direction flips: the engine becomes the writer and the markdown
projection becomes the export — that is a separate, deliberate step.

## Building

```bash
(cd ../inkstone && cargo build --release -p inkstone-ffi)   # static lib + FFI
./scripts/sync-inkstone-bindings.sh ../inkstone             # vendored bindings
swift build                                                  # links libinkstone_ffi.a
```

`Package.swift` links the static library only when `libinkstone_ffi.a` exists;
otherwise `INKSTONE` is not defined and the shadow compiles to no-ops.
