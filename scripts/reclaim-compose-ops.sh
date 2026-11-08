#!/usr/bin/env bash
# Free the whole-body note history that the engine made redundant.
#
#   ./scripts/reclaim-compose-ops.sh [--dry-run]
#
# Safety gates (all must hold, else nothing is deleted):
#   1. the engine is primary (CLIPVAULT_INKSTONE_PRIMARY=1) and enabled;
#   2. every live note exists in the engine (`/api/inkstone/audit` checked == live);
#   3. audit drift is small (<= 2% — markdown rendering differences are expected).
#
# Artifacts written before touching anything:
#   - <home>/markdown-export-<ts>/     every note as markdown + MANIFEST.tsv
#   - <home>/clipflow-before-reclaim-<ts>.db   VACUUM INTO copy of the database
#
# Then it keeps the newest compose_ops row per note (legacy merge base) and
# VACUUMs.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

HOME_DIR="${CLIPVAULT_HOME:-$HOME/Library/Application Support/Keepsake}"
DB="$HOME_DIR/clipflow.db"
VAULT="${CLIPVAULT_INKSTONE_PATH:-$HOME_DIR/inkstone.db}"
INKSTONE="${INKSTONE_REPO:-$HOME/dev/inkstone}"
API="http://127.0.0.1:8080"
TS="$(date +%Y%m%d-%H%M%S)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

echo "[1/4] gates"
curl -s "$API/api/inkstone/audit?limit=2000" > /tmp/reclaim-audit.json
python3 - "$DB" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
live = db.execute("SELECT COUNT(*) FROM clipboard_items WHERE type='note' AND deleted_at IS NULL").fetchone()[0]
a = json.load(open('/tmp/reclaim-audit.json'))
checked, drift, primary = a['checked'], a['drift'], a['enginePrimary']
print(f"      live={live} engine_checked={checked} drift={drift} primary={primary}")
if not primary:
    sys.exit("FAIL: engine is not primary; run scripts/cutover-inkstone.sh on")
if checked < live:
    sys.exit(f"FAIL: only {checked}/{live} notes are in the engine")
if drift > max(2, live * 2 // 100):
    sys.exit(f"FAIL: drift {drift} is too high to prune history")
PY

echo "[2/4] artifacts"
EXPORT="$HOME_DIR/markdown-export-$TS"
( cd "$INKSTONE" && ./target/release/examples/export-markdown --vault "$VAULT" --out "$EXPORT" ) \
  || ( cd "$INKSTONE" && cargo run --release -q -p inkstone-store --example export-markdown -- --vault "$VAULT" --out "$EXPORT" )
BACKUP="$HOME_DIR/clipflow-before-reclaim-$TS.db"
sqlite3 "$DB" "VACUUM INTO '$BACKUP';"
echo "      $EXPORT"
echo "      $BACKUP ($(stat -f%z "$BACKUP") bytes)"

BEFORE_DB=$(stat -f%z "$DB")
BEFORE_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM compose_ops;")
BEFORE_BYTES=$(sqlite3 "$DB" "SELECT COALESCE(SUM(LENGTH(body)),0) FROM compose_ops;")

echo "[3/4] prune compose_ops (keep newest per note)"
if [ "$DRY" = "1" ]; then
  echo "      dry run: would delete $((BEFORE_ROWS - $(sqlite3 "$DB" "SELECT COUNT(DISTINCT item_id) FROM compose_ops;"))) row(s)"
  exit 0
fi
sqlite3 "$DB" <<'SQL'
BEGIN;
DELETE FROM compose_ops
 WHERE rowid NOT IN (
   SELECT rowid FROM (
     SELECT rowid, ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY ts DESC, id DESC) AS rn
       FROM compose_ops
   ) WHERE rn = 1
 );
COMMIT;
VACUUM;
SQL

AFTER_DB=$(stat -f%z "$DB")
AFTER_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM compose_ops;")
echo "[4/4] result"
printf "      compose_ops rows   %s -> %s\n" "$BEFORE_ROWS" "$AFTER_ROWS"
printf "      compose_ops bytes  %s -> %s\n" "$BEFORE_BYTES" "$(sqlite3 "$DB" "SELECT COALESCE(SUM(LENGTH(body)),0) FROM compose_ops;")"
printf "      database file      %.1f MB -> %.1f MB\n" "$(echo "$BEFORE_DB/1048576" | bc -l)" "$(echo "$AFTER_DB/1048576" | bc -l)"
curl -s "$API/api/inkstone/audit?limit=2000" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("      audit after: checked=%s drift=%s" % (d["checked"], d["drift"]))'
sqlite3 "$DB" "SELECT '      notes: ' || COUNT(*) FROM clipboard_items WHERE type='note' AND deleted_at IS NULL;"
