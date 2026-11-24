#!/usr/bin/env python3
"""D0b-v2: nmem 历史 → corpus/nmem.txt（直读 nmem-edge store.sqlite3 快照）。

历程：
- v1: REST /memories（nmem-edge 迁 MCP 后 404）
- v2a: MCP mem_fs + get_memory_by_id —— 每条 ~20s（服务端收敛开销），3902 条不可行
- v2b（本版）: 真源 = d2:/var/lib/nmem-edge/state/store.sqlite3（STRICT 表，本机
  scp 拷贝后 immutable 只读）。活动 Memory = canonical_objects(object_type='Memory')
  排除 tombstones。4520−180 ≈ 3902 与 graph_stats 一致。
增量：watermark.json 记已导 id 集合。

用法: .venv/bin/python data/export_nmem_v2.py [--force] [--db <path>]
"""
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus, is_promising, now_iso

OUT = Path(__file__).resolve().parent.parent / "corpus"
WATERMARK = OUT / "watermark.json"
TMP = Path(__file__).resolve().parent.parent.parent / ".tmp"  # recallfs/.tmp
REMOTE_DB = "d2:/var/lib/nmem-edge/state/store.sqlite3"
DEFAULT_DB = TMP / "nmem_store_ro.sqlite3"


def ensure_store_snapshot(db: Path, max_age_h: float = 1.0) -> Path:
    """快照不存在或超过 max_age_h 小时 → 从 d2 scp 重新拷（只拷主库，immutable 读不吃 wal）。"""
    TMP.mkdir(parents=True, exist_ok=True)
    fresh = db.exists() and (now_ts(db) < max_age_h * 3600)
    if not fresh:
        subprocess.run(["scp", "-q", REMOTE_DB, str(db)], check=True, timeout=600)
    return db


def now_ts(p: Path) -> float:
    import time
    return time.time() - p.stat().st_mtime


def load_memories(db: Path) -> list[dict]:
    con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
    tomb = {r[0] for r in con.execute("SELECT edge_id FROM tombstones")}
    rows = con.execute(
        "SELECT edge_id, canonical_json FROM canonical_objects WHERE object_type='Memory'"
    ).fetchall()
    con.close()
    out, seen_ids = [], set()
    for edge_id, cj in rows:
        if edge_id in tomb:
            continue
        try:
            m = json.loads(cj)
        except Exception:
            continue
        mid = m.get("id") or edge_id
        if mid in seen_ids:
            continue
        seen_ids.add(mid)
        out.append(m)
    return out


def export(db: Path | None = None, incremental: bool = True) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    db = Path(db) if db else ensure_store_snapshot(DEFAULT_DB)
    wm = json.loads(WATERMARK.read_text()) if WATERMARK.exists() else {}
    seen = set(wm.get("nmem_v2_seen_ids", []))

    stats = {"db": str(db), "rows": 0, "new": 0, "skipped": 0, "too_short": 0}
    new_docs, new_ids = [], []
    for m in load_memories(db):
        stats["rows"] += 1
        mid = m.get("id") or ""
        if incremental and mid in seen:
            stats["skipped"] += 1
            continue
        text = (str(m.get("title") or "") + "\n" + str(m.get("content") or "")).strip()
        text = clean_text(text)
        if not is_promising(text):
            stats["too_short"] += 1
            continue
        new_docs.append(text)
        new_ids.append(mid)
        stats["new"] += 1

    wm["nmem_v2_seen_ids"] = sorted(set(seen) | set(new_ids))
    wm["nmem_v2_updated_at"] = now_iso()
    WATERMARK.write_text(json.dumps(wm, ensure_ascii=False, indent=1))

    nmem_txt = OUT / "nmem.txt"
    old = nmem_txt.read_text(encoding="utf-8") if nmem_txt.exists() else ""
    docs_old = [d for d in old.split(DOC_SEPARATOR) if d.strip()]
    nmem_txt.write_text(docs_to_corpus(docs_old + new_docs), encoding="utf-8")
    stats["total_docs"] = len(docs_old) + len(new_docs)
    return stats


if __name__ == "__main__":
    db = None
    if "--db" in sys.argv:
        db = Path(sys.argv[sys.argv.index("--db") + 1])
    print(json.dumps(export(db, incremental="--force" not in sys.argv),
                     ensure_ascii=False, indent=1))
