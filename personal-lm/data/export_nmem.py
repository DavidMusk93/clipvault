#!/usr/bin/env python3
"""D0b: nmem 历史 → corpus/nmem.txt

经本地 nmem API（127.0.0.1:14242，凭据 ~/.nowledge-mem/config.json）分页拉取
全部 active memories（title + content）。threads 不导（过程性对话，价值低且重复）。

增量：corpus/watermark.json 记已导出的 memory id 集合的 hash 摘要；
简单起见按 id 全量比对，跳过已见 id。
"""
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus, is_promising, now_iso

CFG = Path.home() / ".nowledge-mem/config.json"
OUT = Path(__file__).resolve().parent.parent / "corpus"
WATERMARK = OUT / "watermark.json"
PAGE = 100


def api_get(path: str, key: str) -> dict:
    req = urllib.request.Request(
        f"http://127.0.0.1:14242{path}", headers={"Authorization": f"Bearer {key}"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def fetch_all(key: str) -> list[dict]:
    out, offset = [], 0
    while True:
        d = api_get(f"/memories?limit={PAGE}&offset={offset}&state=active", key)
        batch = d.get("memories", [])
        if not batch:
            break
        out.extend(batch)
        pg = d.get("pagination") or {}
        total = pg.get("total")
        offset += len(batch)
        if total is not None and offset >= total:
            break
        if len(batch) < PAGE:
            break
    return out


def export(incremental: bool = False) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    key = json.loads(CFG.read_text())["apiKey"]
    wm = json.loads(WATERMARK.read_text()) if WATERMARK.exists() else {}
    seen = set(wm.get("nmem_seen_ids", []))

    memories = fetch_all(key)
    stats = {"fetched": len(memories), "new": 0, "skipped": 0, "too_short": 0, "filtered_chars": 0}
    new_docs, new_ids = [], []
    for m in memories:
        mid = m.get("id", "")
        if incremental and mid in seen:
            stats["skipped"] += 1
            continue
        title = (m.get("title") or "").strip()
        content = clean_text(m.get("content") or "")
        # title 常含 '#' 前缀正文片段；去重避免重复拼接
        if title and content.startswith(title[:40]):
            full = content
        else:
            full = f"# {title}\n\n{content}" if title else content
        if not is_promising(full, min_chars=20):
            stats["too_short"] += 1
            continue
        new_docs.append(full)
        new_ids.append(mid)
        stats["new"] += 1

    out = OUT / "nmem.txt"
    mode = "a" if (incremental and stats["skipped"] > 0) else "w"
    with out.open(mode, encoding="utf-8") as f:
        if mode == "w":
            body = docs_to_corpus(new_docs)
        else:
            body = DOC_SEPARATOR + DOC_SEPARATOR.join(new_docs) + DOC_SEPARATOR
        f.write(body)

    seen.update(new_ids)
    wm2 = {**wm, "nmem_seen_ids": sorted(seen), "nmem_last_export": now_iso()}
    WATERMARK.write_text(json.dumps(wm2, ensure_ascii=False, indent=1))
    stats["mode"] = "incremental" if incremental else "full"
    stats["bytes"] = out.stat().st_size
    return stats


if __name__ == "__main__":
    incremental = "--incremental" in sys.argv
    s = export(incremental=incremental)
    print(json.dumps(s, ensure_ascii=False, indent=1))
