#!/usr/bin/env python3
"""D0c: 合并语料 → corpus/all.txt + corpus/manifest.json（统计落盘）。"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import now_iso

OUT = Path(__file__).resolve().parent.parent / "corpus"


def split_docs(text: str) -> list[str]:
    return [d for d in text.split("<|doc|>") if d.strip()]


def main() -> None:
    weighted = "--weighted" in sys.argv
    parts = {}
    for name in ("clipflow", "nmem", "lark", "repos", "en_arxiv_csdb", "en_papers_classic"):
        p = OUT / f"{name}.txt"
        parts[name] = p.read_text(encoding="utf-8") if p.exists() else ""
    merged = OUT / "all.txt"
    merged.write_text("\n\n".join(v for v in parts.values() if v.strip()), encoding="utf-8")

    if weighted:
        # 打字面加权：用户手写的 ×4/×3，OCR 噪声 ×0.5，nmem(自己写的精炼记忆) ×2
        cat = OUT / "categories"
        def docs_of(name):
            p = cat / f"{name}.txt"
            return split_docs(p.read_text(encoding="utf-8")) if p.exists() else []
        weighted_groups = [
            (docs_of("compose"), 4),   # 笔记正文 = 最贴近补全目标
            (docs_of("note"), 3),      # 手写笔记
            (docs_of("anno"), 4),      # 用户批注
            (docs_of("text"), 1),      # 复制文本
            ([d for i, d in enumerate(docs_of("ocr")) if i % 2 == 0], 1),  # OCR 减半（噪声大）
        ]
        nmem_docs = split_docs(parts["nmem"])
        lark_docs = split_docs(parts["lark"])
        repos_docs = split_docs(parts["repos"])
        # 英文域语料：克制加权（词汇/语法骨架，防正式书面语盖过个人风格）
        arxiv_docs = split_docs(parts["en_arxiv_csdb"])
        papers_docs = split_docs(parts["en_papers_classic"])
        chunks = []
        for group, w in weighted_groups:
            chunks.extend(group * w)
        chunks.extend(nmem_docs * 2)
        chunks.extend(lark_docs * 2)            # 聊天 = 高频真实打字面
        chunks.extend(repos_docs * 2)           # 个人仓库思考/设计沉淀（用户指定）
        chunks.extend(arxiv_docs * 1)           # 英文摘要
        chunks.extend(papers_docs * 1)          # 经典论文全文
        merged = OUT / "all_weighted.txt"
        merged.write_text("<|doc|>".join(chunks), encoding="utf-8")

    text = merged.read_text(encoding="utf-8")
    manifest = {
        "built": now_iso(),
        "sources": {k: {"chars": len(v)} for k, v in parts.items()},
        "total_chars": len(text),
        "approx_tokens_bytes": len(text.encode("utf-8")),
        "files": sorted(p.name for p in OUT.glob("*") if p.is_file()),
    }
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
