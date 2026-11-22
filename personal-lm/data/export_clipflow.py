#!/usr/bin/env python3
"""D0a: clipflow.db → corpus/clipflow.txt

来源（全部 alive，deleted_at IS NULL）：
- clipboard_items.type='text'   → text_content（按 content_hash 去重）
- clipboard_items.type='note'   → text_content（笔记全保留）
- compose_ops                   → title + body（笔记本正文，5k+ 条）
- clipboard_items.ocr_text      → 截图 OCR 文字
- clipboard_items.user_note / judgment_text → 用户自己的批注

增量：corpus/watermark.json 记 last_ts，只导新增（--incremental）。
"""
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus, is_promising, now_iso

DB = Path.home() / "Library/Application Support/Keepsake/clipflow.db"
OUT = Path(__file__).resolve().parent.parent / "corpus"
WATERMARK = OUT / "watermark.json"


def load_watermark() -> dict:
    if WATERMARK.exists():
        return json.loads(WATERMARK.read_text())
    return {}


def save_watermark(wm: dict) -> None:
    WATERMARK.write_text(json.dumps(wm, ensure_ascii=False, indent=1))


def export(incremental: bool = False) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    wm = load_watermark() if incremental else {}
    last_ts = wm.get("clipflow_last_ts", 0.0)

    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    stats = {"clips": 0, "notes": 0, "compose": 0, "ocr": 0, "annotations": 0,
             "deduped": 0, "too_short": 0}

    # ---- 1) text clips：按 content_hash 去重，保留最新一条 ----
    rows = con.execute(
        """SELECT content_hash, timestamp, text_content, source_app
           FROM clipboard_items
           WHERE deleted_at IS NULL AND type='text'
             AND text_content IS NOT NULL AND length(text_content) > 0
             AND timestamp > ?
           ORDER BY timestamp ASC""",
        (last_ts,),
    ).fetchall()
    seen_hashes = set()
    docs = []
    for r in rows:
        if r["content_hash"] in seen_hashes:
            stats["deduped"] += 1
            continue
        seen_hashes.add(r["content_hash"])
        text = clean_text(r["text_content"])
        if not is_promising(text):
            stats["too_short"] += 1
            continue
        docs.append(text)
        stats["clips"] += 1

    # ---- 2) notes（个人笔记全保留，不去重）----
    rows = con.execute(
        """SELECT text_content FROM clipboard_items
           WHERE deleted_at IS NULL AND type='note'
             AND text_content IS NOT NULL AND length(text_content) > 0
             AND timestamp > ?
           ORDER BY timestamp ASC""",
        (last_ts,),
    ).fetchall()
    note_docs = []
    for r in rows:
        text = clean_text(r["text_content"])
        if not is_promising(text):
            stats["too_short"] += 1
            continue
        note_docs.append(text)
        stats["notes"] += 1

    # ---- 3) compose_ops 笔记本正文（v2: 同一 item_id 只留最新版本，
    #         5310 行历史版本实际只有 ~374 条不同笔记）----
    rows = con.execute(
        """SELECT title, body FROM compose_ops c
           WHERE ts > ?
             AND ts = (SELECT MAX(ts) FROM compose_ops c2 WHERE c2.item_id = c.item_id)
           ORDER BY ts ASC""",
        (last_ts,),
    ).fetchall()
    compose_docs = []
    for r in rows:
        title = (r["title"] or "").strip()
        body = clean_text(r["body"] or "")
        full = (f"# {title}\n\n{body}" if title else body)
        if not is_promising(full, min_chars=20):
            stats["too_short"] += 1
            continue
        compose_docs.append(full)
        stats["compose"] += 1

    # ---- 4) OCR（截图文字，≥40 字符才要）----
    rows = con.execute(
        """SELECT ocr_text FROM clipboard_items
           WHERE deleted_at IS NULL AND ocr_text IS NOT NULL
             AND length(ocr_text) > 40 AND timestamp > ?""",
        (last_ts,),
    ).fetchall()
    ocr_docs = []
    for r in rows:
        text = clean_text(r["ocr_text"])
        if is_promising(text, min_chars=40):
            ocr_docs.append(text)
            stats["ocr"] += 1

    # ---- 5) 用户批注 ----
    rows = con.execute(
        """SELECT user_note, judgment_text FROM clipboard_items
           WHERE deleted_at IS NULL
             AND ((user_note IS NOT NULL AND length(user_note) > 10)
               OR (judgment_text IS NOT NULL AND length(judgment_text) > 10))
             AND timestamp > ?""",
        (last_ts,),
    ).fetchall()
    anno_docs = []
    for r in rows:
        for col in ("user_note", "judgment_text"):
            if r[col] and len(r[col]) > 10:
                text = clean_text(r[col])
                if text:
                    anno_docs.append(text)
                    stats["annotations"] += 1

    max_ts = con.execute(
        "SELECT COALESCE(MAX(timestamp), 0) FROM clipboard_items WHERE deleted_at IS NULL"
    ).fetchone()[0]
    compose_max_ts = con.execute("SELECT COALESCE(MAX(ts), 0) FROM compose_ops").fetchone()[0]
    con.close()

    # ---- 分类文件（v2 加权训练用）----
    cat_dir = OUT / "categories"
    cat_dir.mkdir(exist_ok=True)
    for name, group in (("compose", compose_docs), ("note", note_docs),
                        ("text", docs), ("ocr", ocr_docs), ("anno", anno_docs)):
        f = cat_dir / f"{name}.txt"
        if incremental and last_ts > 0 and f.exists():
            with f.open("a", encoding="utf-8") as fh:
                fh.write(DOC_SEPARATOR.join(group) + DOC_SEPARATOR)
        else:
            f.write_text(DOC_SEPARATOR.join(group), encoding="utf-8")

    # ---- 写盘（增量 = 追加；全量 = 覆盖）----
    mode = "a" if (incremental and last_ts > 0) else "w"
    out = OUT / "clipflow.txt"
    sep = "" if (mode == "w" or out.stat().st_size == 0) else DOC_SEPARATOR
    with out.open(mode, encoding="utf-8") as f:
        if mode == "w":
            pass
        chunks = []
        if sep:
            chunks.append(sep)
        for group in (compose_docs, note_docs, docs, ocr_docs, anno_docs):
            for d in group:
                chunks.append(d)
                chunks.append(DOC_SEPARATOR)
        f.write("".join(chunks))

    new_wm = {"clipflow_last_ts": max(max_ts, compose_max_ts), "updated": now_iso()}
    if incremental:
        new_wm = {**wm, **new_wm}
    save_watermark(new_wm)
    stats["mode"] = "incremental" if incremental else "full"
    stats["bytes"] = out.stat().st_size
    return stats


if __name__ == "__main__":
    incremental = "--incremental" in sys.argv
    s = export(incremental=incremental)
    print(json.dumps(s, ensure_ascii=False, indent=1))
