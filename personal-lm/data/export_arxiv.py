#!/usr/bin/env python3
"""D0e: arXiv cs.DB（数据库领域）英文语料 → corpus/en_arxiv_csdb.txt。

目的：英文补全/生成能力的领域语料。选 cs.DB 是因为与用户工作域
（存储/查询/分布式/OLAP）词汇高度重叠，比泛英文语料训练价值高。
来源 = arXiv API（开放）。取 title+abstract（正文版权复杂，个人本地训练
可用，但摘要已能覆盖术语与句式；后续可选拉 LaTeX 全文）。

用法: .venv/bin/python data/export_arxiv.py [max_papers=4000]
"""
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus, is_promising

OUT = Path(__file__).resolve().parent.parent / "corpus"
UA = "clipvault-personal-lm-corpus/0.1 (local personal use; contact: local)"

QUERY = '(cat:cs.DB OR cat:cs.DC) AND (database OR "storage engine" OR "query optimization" OR "distributed transaction")'
PAGE = 100


def fetch_batch(start: int, retries: int = 6) -> str:
    q = urllib.parse.quote(QUERY)
    url = (f"https://export.arxiv.org/api/query?search_query={q}"
           f"&start={start}&max_results={PAGE}&sortBy=submittedDate"
           f"&sortOrder=descending")
    import time as _t
    delay = 60
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:
            last = e
            print(f"[arxiv] start={start} attempt={attempt} err={e} → retry in {delay}s", flush=True)
            _t.sleep(delay)
            delay = min(delay * 2, 900)
    raise last


def parse_atom(xml: str) -> list[dict]:
    papers = []
    for entry in re.findall(r"<entry>(.*?)</entry>", xml, re.S):
        title = re.search(r"<title>(.*?)</title>", entry, re.S)
        summary = re.search(r"<summary>(.*?)</summary>", entry, re.S)
        published = re.search(r"<published>(\d{4})", entry)
        if not (title and summary):
            continue
        clean = lambda s: re.sub(r"\s+", " ", s.replace("\n", " ")).strip()
        papers.append({
            "title": clean(title.group(1)),
            "abstract": clean(summary.group(1)),
            "year": published.group(1) if published else "",
        })
    return papers


def export(max_papers: int = 4000) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    docs, years = [], {}
    for start in range(0, max_papers, PAGE):
        xml = fetch_batch(start)
        batch = parse_atom(xml)
        if not batch:
            break
        for p in batch:
            doc = f"{p['title']}\n\n{p['abstract']}"
            doc = clean_text(doc)
            if is_promising(doc, 60):
                docs.append(doc)
                years[p["year"]] = years.get(p["year"], 0) + 1
        time.sleep(10)  # arXiv API 礼仪（曾 429）：~1 req/10s + 指数退避重试
        print(f"[arxiv] {start + len(batch)} papers", flush=True)
    path = OUT / "en_arxiv_csdb.txt"
    path.write_text(docs_to_corpus(docs), encoding="utf-8")
    return {"docs": len(docs), "bytes": path.stat().st_size, "years": dict(sorted(years.items()))}


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
    print(json.dumps(export(n), ensure_ascii=False, indent=1))
