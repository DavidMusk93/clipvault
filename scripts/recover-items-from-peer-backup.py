#!/usr/bin/env python3
"""Recover ClipVault items whose op log was destroyed by a peer seq rewind.

Background (incident 2026-10-09): a peer can rewrite already-published `trx/{host}/{seq}.json`
files when its seq counter goes backwards (two server instances clobbering `sync.next_seq`).
Every peer whose `sync.applied.{host}` high-water mark is already past those seqs will never
read them again, and the ops are gone from the transport forever. The rows still exist in the
peer's own DB (+ its backup slice), so they can be imported out of band.

Source of truth: the peer's backup slice in the shared cloud root
  .../ClipFlow/backup/hosts/{peer}/latest/clipflow.db
  .../ClipFlow/backup/hosts/{peer}/blobs/{key}.bin

What it does (only for items that exist there and have NO local representation):
  1. copy the item row into the live DB (explicit column list; schemas differ in column order)
  2. insert the matching clipboard_fts row (this DB has no FTS triggers; the app writes them itself)
  3. copy compose_ops rows for imported notes (history for the merge hashing)
  4. copy binary blobs into the local CAS blobs/{key}.bin

Usage:
  scripts/recover-items-from-peer-backup.py --peer <hostId>            # dry run
  scripts/recover-items-from-peer-backup.py --peer <hostId> --apply    # write
"""
import os
import re
import shutil
import sqlite3
import sys

HOME_ID = os.environ.get("CLIPVAULT_PEER", "")
for i, arg in enumerate(sys.argv):
    if arg == "--peer" and i + 1 < len(sys.argv):
        HOME_ID = sys.argv[i + 1]
APPLY = "--apply" in sys.argv
if not HOME_ID:
    print(__doc__)
    print("error: --peer <hostId> is required (or set CLIPVAULT_PEER)", file=sys.stderr)
    sys.exit(2)

BACKUP = os.path.expanduser(
    f"~/Library/Mobile Documents/com~apple~CloudDocs/ClipFlow/backup/hosts/{HOME_ID}"
)
HOME_DB = f"{BACKUP}/latest/clipflow.db"
HOME_BLOBS = f"{BACKUP}/blobs"
LIVE_ATTACH = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/ClipFlow/live/attach"
)
LOCAL_DB = os.environ.get(
    "CLIPVAULT_DB",
    os.path.expanduser("~/Library/Application Support/Keepsake/clipflow.db"),
)
LOCAL_BLOBS = os.path.join(os.path.dirname(LOCAL_DB), "blobs")

norm = lambda s: re.sub(r"\s+", "", s or "")


def main() -> int:
    if not os.path.exists(HOME_DB):
        print(f"error: peer backup not found: {HOME_DB}", file=sys.stderr)
        return 2
    home = sqlite3.connect(f"file:{HOME_DB}?mode=ro&immutable=1", uri=True)
    # No `immutable=1` here: the live DB is in WAL mode, and an immutable connection silently
    # reads a stale snapshot (it ignores the WAL) — which would re-plan already-imported rows.
    me = sqlite3.connect(f"file:{LOCAL_DB}?mode=ro", uri=True)
    mine = {r[0] for r in me.execute("select id from clipboard_items")}
    hashes = {r[0] for r in me.execute("select content_hash from clipboard_items")}
    texts = {r[0] for r in me.execute("select text_content from clipboard_items where text_content is not null")}
    ntexts = {norm(t) for t in texts}
    htmls = {r[0] for r in me.execute("select html_content from clipboard_items where html_content is not null")}
    home_cols = [r[1] for r in home.execute("pragma table_info(clipboard_items)")]
    local_cols = [r[1] for r in me.execute("pragma table_info(clipboard_items)")]
    cols = [c for c in local_cols if c in home_cols]
    me.close()

    missing = []
    for row in home.execute("select * from clipboard_items"):
        d = dict(zip(home_cols, row))
        if d["id"] in mine or d["content_hash"] in hashes:
            continue
        if d["text_content"] and (d["text_content"] in texts or norm(d["text_content"]) in ntexts):
            continue
        if d["html_content"] and d["html_content"] in htmls:
            continue
        missing.append(d)
    missing.sort(key=lambda d: d["timestamp"])

    plan_blobs, plan_notes = [], []
    for d in missing:
        for key in (d["content_hash"], d["content_hash"] + ".rtf", d["content_hash"] + ".pdf"):
            dest = os.path.join(LOCAL_BLOBS, key + ".bin")
            if os.path.exists(dest):
                break
            src = next((p for p in (os.path.join(HOME_BLOBS, key + ".bin"),
                                    os.path.join(LIVE_ATTACH, key + ".bin"))
                        if os.path.exists(p)), None)
            if src:
                plan_blobs.append((src, dest, key))
                break
        if d["type"] == "note":
            plan_notes.append(d["id"])

    print(f"source   : {HOME_DB}")
    print(f"target   : {LOCAL_DB}")
    print(f"to import: {len(missing)} items | blobs: {len(plan_blobs)} | notes with op history: {len(plan_notes)}")
    for d in missing:
        print(f"  {d['id'][:8]} {d['type']:6} {d['content_hash'][:10]} {str(d['text_content'])[:34]!r}")
    if not APPLY:
        print("\ndry run. add --apply to write.")
        return 0

    os.makedirs(LOCAL_BLOBS, exist_ok=True)
    for src, dest, key in plan_blobs:
        shutil.copyfile(src, dest)
        print(f"blob  {key[:12]} <- {os.path.basename(os.path.dirname(src))} ({os.path.getsize(dest)} B)")

    db = sqlite3.connect(LOCAL_DB, timeout=30)
    db.execute("pragma busy_timeout=30000")
    placeholders = ",".join("?" * len(cols))
    ins_item = f"insert into clipboard_items ({','.join(cols)}) values ({placeholders})"
    ins_fts = ("insert into clipboard_fts (id, text_content, ocr_text, source_app, html_content, judgment_text) "
               "values (?,?,?,?,?,?)")
    ins_op = ("insert or ignore into compose_ops "
              "(id,item_id,ts,title,body,ref_item_id,blob_keys,source,parent_hash,content_hash) "
              "values (?,?,?,?,?,?,?,?,?,?)")
    home_op_cols = [r[1] for r in home.execute("pragma table_info(compose_ops)")]

    db.execute("begin immediate")
    added_items = added_fts = added_ops = 0
    for d in missing:
        db.execute(ins_item, [d[c] for c in cols])
        added_items += 1
        db.execute(ins_fts, (d["id"], d["text_content"], d["ocr_text"], d["source_app"],
                             d["html_content"], d["judgment_text"]))
        added_fts += 1
        if d["type"] == "note":
            for o in home.execute("select * from compose_ops where item_id=?", (d["id"],)):
                od = dict(zip(home_op_cols, o))
                db.execute(ins_op, (od["id"], od["item_id"], od["ts"], od.get("title"), od["body"],
                                    od.get("ref_item_id"), od.get("blob_keys"),
                                    f"sync:{HOME_ID}", od.get("parent_hash"), od.get("content_hash")))
                added_ops += 1
    db.commit()
    db.close()
    print(f"\nwrote: items={added_items} fts={added_fts} compose_ops={added_ops}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
