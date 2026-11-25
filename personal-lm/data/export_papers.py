#!/usr/bin/env python3
"""D0f: CPU/mem/IO/database 经典论文全文 → corpus/en_papers_classic.txt。

来源 = 各论文的稳定公开托管点（作者页/USENIX/CIDR/Google Research/MIT），
404 时按标题走 arXiv 兜底；两处都没有 → 记录跳过。
PDF 文本用 pypdf 抽取，清洗复用 common。
版权边界（PRIVACY.md）：论文全文仅本地个人训练用，绝不进 git/公共渠道。

用法: .venv/bin/python data/export_papers.py [slug ...]
"""
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus

OUT = Path(__file__).resolve().parent.parent / "corpus"
TMP = Path(__file__).resolve().parent.parent.parent / ".tmp" / "papers"
UA = "Mozilla/5.0 (personal-lm corpus; local personal use)"

PAPERS = [
    # ---- 数据库体系与存储 ----
    ("arch_of_db_system", "Architecture of a Database System",
     ["https://dsf.berkeley.edu/papers/fntdb07-architecture.pdf"]),
    ("lsmtree", "The Log-Structured Merge-Tree (LSM-Tree)",
     ["http://www.cs.umb.edu/~poneil/lsmtree.pdf"]),
    ("wisckey", "WiscKey: Separating Keys from Values in SSD-Conscious Storage",
     ["https://www.usenix.org/system/files/conference/fast16/fast16-pb-lu.pdf"]),
    ("gfs", "The Google File System",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/gfs-sosp2003.pdf"]),
    ("mapreduce", "MapReduce: Simplified Data Processing on Large Clusters",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/mapreduce-osdi04.pdf"]),
    ("bigtable", "Bigtable: A Distributed Storage System for Structured Data",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/bigtable-osdi06.pdf",
      "https://static.googleusercontent.com/media/research.google.com/en//archive/bigtable-hosp06.pdf"]),
    ("spanner", "Spanner: Google's Globally-Distributed Database",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/spanner-osdi2012.pdf"]),
    ("f1", "F1: A Distributed SQL Database That Scales",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/f1-vldb13.pdf"]),
    ("megastore", "Megastore: Providing Scalable, Highly Available Storage",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/megastore-atc12.pdf"]),
    ("dynamo", "Dynamo: Amazon's Highly Available Key-value Store",
     ["https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf"]),
    ("raft", "In Search of an Understandable Consensus Algorithm (Raft)",
     ["https://raft.github.io/raft.pdf"]),
    ("paxos_simple", "Paxos Made Simple",
     ["https://lamport.azurewebsites.net/pubs/paxos-simple.pdf"]),
    ("part_time_parliament", "The Part-Time Parliament",
     ["https://lamport.azurewebsites.net/pubs/lamport-paxos.pdf"]),
    ("x100", "MonetDB/X100: Hyper-Pipelined Query Execution",
     ["http://www.cidrdb.org/cidr2005/papers/P19.pdf"]),
    ("aries", "ARIES: A Transaction Recovery Method Supporting Fine-Granularity Locking",
     ["https://www.cs.cmu.edu/~pavlo/blog/2016/aries.pdf",
      "https://people.eecs.berkeley.edu/~brewer/cs262b/Aries.pdf"]),
    ("cstore", "C-Store: A Column-oriented DBMS",
     ["https://vldb.org/pvldb/1/1454168.pdf",
      "https://vldb.org/archives/website/files/2005/p509-stonebraker.pdf"]),
    ("five_minute_rule", "The 5 Minute Rule for Trading Memory for Disc Access",
     ["https://static.googleusercontent.com/media/research.google.com/en//archive/fiveminuterule.pdf"]),
    # ---- CPU / 内存 / IO / 分布式经典 ----
    ("cpumemory", "What Every Programmer Should Know About Memory",
     ["https://www.akkadia.org/drepper/cpumemory.pdf",
      "https://people.freebsd.org/~lstewart/articles/cpumemory.pdf"]),
    ("end_to_end", "End-to-End Arguments in System Design",
     ["https://web.mit.edu/Saltzer/www/publications/endtoend/endtoend.pdf"]),
    ("hints_system_design", "Hints for Computer System Design",
     ["https://lamport.azurewebsites.net/pubs/hints.pdf",
      "https://www.microsoft.com/en-us/research/uploads/prod/2019/04/hints.pdf"]),
    ("byzantine", "The Byzantine Generals Problem",
     ["https://lamport.azurewebsites.net/pubs/byz.pdf"]),
    ("time_clocks", "Time, Clocks, and the Ordering of Events",
     ["https://lamport.azurewebsites.net/pubs/time-clocks.pdf"]),
    ("snowflake", "The Snowflake Elastic Data Warehouse",
     ["https://www.cidrdb.org/cidr2015/Papers/CIDR15_Paper16.pdf"]),
    ("roofline", "Roofline: An Insightful Visual Performance Model",
     ["https://crd-legacy.lbl.gov/~oliker/papers/roofline.pdf"]),
]


def _open(url: str, timeout: int = 60):
    """urllib 打开；SSL 证书校验失败（venv 无 certifi 链）时退回不校验 —— 只取 PDF 内容。"""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.URLError as e:
        if "CERTIFICATE_VERIFY_FAILED" in str(e):
            import ssl
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            return urllib.request.urlopen(req, timeout=timeout, context=ctx)
        raise


def download(slug: str, urls: list[str]) -> Path | None:
    dst = TMP / f"{slug}.pdf"
    if dst.exists() and dst.stat().st_size > 10_000:
        return dst
    TMP.mkdir(parents=True, exist_ok=True)
    for url in urls:
        try:
            with _open(url) as r:
                data = r.read()
            if data[:4] == b"%PDF" or data[:2] == b"\x1f\x8b":  # pdf / gzip
                dst.write_bytes(data)
                return dst
        except Exception:
            continue
    return None


def arxiv_pdf(title: str, slug: str) -> Path | None:
    """标题精确度低的兜底：arXiv 检索 → 第一个命中 PDF。"""
    q = urllib.parse.quote(f'ti:"{title[:80]}"')
    url = f"https://export.arxiv.org/api/query?search_query={q}&max_results=1"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r:
            xml = r.read().decode("utf-8", "replace")
        import re
        m = re.search(r"<id>http://arxiv.org/abs/([^<]+)</id>", xml)
        if not m:
            return None
        pdf_url = f"https://arxiv.org/pdf/{m.group(1)}"
        dst = TMP / f"{slug}.pdf"
        with urllib.request.urlopen(urllib.request.Request(pdf_url, headers={"User-Agent": UA}),
                                    timeout=120) as r:
            dst.write_bytes(r.read())
        return dst
    except Exception:
        return None


def extract_text(pdf: Path) -> str:
    from pypdf import PdfReader
    reader = PdfReader(str(pdf))
    pages = []
    for p in reader.pages:
        try:
            pages.append(p.extract_text() or "")
        except Exception:
            continue
    return "\n".join(pages)


def s2_pdf(title: str, slug: str, retries: int = 5) -> Path | None:
    """Semantic Scholar 开放获取 PDF 兜底（按标题检索；429 指数退避）。"""
    import time as _t
    delay = 4
    d = None
    for attempt in range(retries):
        try:
            q = urllib.parse.quote(title)
            url = ("https://api.semanticscholar.org/graph/v1/paper/search"
                   f"?query={q}&fields=title,openAccessPdf&limit=3")
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with _open(url, timeout=60) as r:
                d = json.loads(r.read())
            break
        except Exception as e:
            print(f"[papers] s2 {slug} attempt={attempt}: {e}", flush=True)
            if "429" in str(e):
                _t.sleep(delay)
                delay = min(delay * 2, 60)
                continue
            return None
    if not d:
        return None
    for paper in d.get("data", []):
        oa = (paper.get("openAccessPdf") or {}).get("url")
        if not oa:
            continue
        dst = TMP / f"{slug}.pdf"
        try:
            with _open(oa, timeout=120) as r:
                data = r.read()
            if data[:4] == b"%PDF":
                dst.write_bytes(data)
                return dst
        except Exception:
            continue
    return None


def export(slugs: list[str] | None = None) -> dict:
    TMP.mkdir(parents=True, exist_ok=True)
    docs, failed = [], []
    for slug, title, urls in PAPERS:
        if slugs and slug not in slugs:
            continue
        pdf = download(slug, urls)
        src = "mirror"
        if pdf is None:
            pdf = s2_pdf(title, slug)
            src = "s2"
        if pdf is None:
            pdf = arxiv_pdf(title, slug)
            src = "arxiv"
        if pdf is None or pdf.stat().st_size < 10_000:
            failed.append(f"{slug}: no source")
            continue
        try:
            text = extract_text(pdf)
        except Exception as e:
            failed.append(f"{slug}: extract {e}")
            continue
        text = clean_text(text)
        if len(text) < 500:
            failed.append(f"{slug}: text too short ({len(text)})")
            continue
        docs.append(f"{title}\n\n{text}")
        print(f"[papers] {slug}: {len(text)} chars ({src})", flush=True)
    path = OUT / "en_papers_classic.txt"
    # 增量合并：按首行（标题）去重，保留历史成功项 —— 分批补拉时不再互相覆盖
    old = path.read_text(encoding="utf-8") if path.exists() else ""
    old_docs = [d for d in old.split(DOC_SEPARATOR) if d.strip()]
    titles = {d.splitlines()[0] for d in docs}
    for d in old_docs:
        t = d.splitlines()[0]
        if t not in titles:
            docs.append(d)
            titles.add(t)
    path.write_text(docs_to_corpus(docs), encoding="utf-8")
    return {"docs": len(docs), "bytes": path.stat().st_size, "failed": failed}


if __name__ == "__main__":
    subprocess.run([str(Path(sys.executable).parent / "pip"), "install", "-q", "pypdf"],
                   capture_output=True, text=True)
    print(json.dumps(export(sys.argv[1:] or None), ensure_ascii=False, indent=1))
