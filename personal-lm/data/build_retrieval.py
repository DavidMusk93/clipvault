#!/usr/bin/env python3
"""构建检索索引（行级）：compose 最新版正文 + 手写笔记 + 复制文本 + nmem。
私有声像：输出 corpus/retrieval_lines.jsonl，只落本地（.gitignore 已含 corpus/）。
评测诚实性：排除 autocomplete 评测用的最新 60 条 compose item（与 eval 同 SQL）。
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import clean_line, now_iso  # noqa: E402

DB = Path.home() / "Library/Application Support/Keepsake/clipflow.db"
NMEM_CFG = Path.home() / ".nowledge-mem/config.json"
OUT = Path(__file__).resolve().parent.parent / "corpus" / "retrieval_lines.jsonl"
EVAL_EXCLUDE = 60


def add_doc(out: set, doc: str):
    for raw in doc.splitlines():
        line = clean_line(raw.strip())
        if line and 6 <= len(line) <= 200 and not line.startswith("<|"):
            out.add(line)


def main():
    import sqlite3
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    lines: set[str] = set()

    # compose：评测排除集之外的全部最新版正文
    rows = con.execute(
        """SELECT body FROM compose_ops c
           WHERE c.item_id NOT IN (
             SELECT item_id FROM compose_ops c3
             WHERE c3.ts = (SELECT MAX(ts) FROM compose_ops c2 WHERE c2.item_id = c3.item_id)
             ORDER BY c3.ts DESC LIMIT ?
           )
             AND c.ts = (SELECT MAX(ts) FROM compose_ops c2 WHERE c2.item_id = c.item_id)""",
        (EVAL_EXCLUDE,),
    ).fetchall()
    for (body,) in rows:
        add_doc(lines, body or "")

    # 手写笔记 + 复制文本（去重后）
    for r in con.execute(
        """SELECT text_content FROM clipboard_items
           WHERE deleted_at IS NULL AND type IN ('note','text')
             AND text_content IS NOT NULL AND length(text_content) > 20
           GROUP BY content_hash"""
    ).fetchall():
        add_doc(lines, r[0])

    # 用户批注
    for r in con.execute(
        """SELECT user_note FROM clipboard_items
           WHERE deleted_at IS NULL AND user_note IS NOT NULL AND length(user_note) > 10"""
    ).fetchall():
        add_doc(lines, r[0])
    con.close()

    # nmem（自己的精炼记忆）
    if NMEM_CFG.exists():
        key = json.loads(NMEM_CFG.read_text())["apiKey"]
        import urllib.request
        offset = 0
        while True:
            req = urllib.request.Request(
                f"http://127.0.0.1:14242/memories?limit=100&offset={offset}&state=active",
                headers={"Authorization": f"Bearer {key}"})
            d = json.loads(urllib.request.urlopen(req, timeout=30).read())
            batch = d.get("memories", [])
            if not batch:
                break
            for m in batch:
                add_doc(lines, (m.get("title") or "") + "\n" + (m.get("content") or ""))
            offset += len(batch)
            if len(batch) < 100:
                break

    out_lines = sorted(lines)
    OUT.write_text("\n".join(out_lines), encoding="utf-8")
    print(json.dumps({"lines": len(out_lines), "built": now_iso()}, ensure_ascii=False))


if __name__ == "__main__":
    main()
