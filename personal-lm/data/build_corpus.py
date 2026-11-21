#!/usr/bin/env python3
"""D0c: 合并语料 → corpus/all.txt + corpus/manifest.json（统计落盘）。"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import now_iso

OUT = Path(__file__).resolve().parent.parent / "corpus"


def main() -> None:
    parts = {}
    for name in ("clipflow", "nmem"):
        p = OUT / f"{name}.txt"
        parts[name] = p.read_text(encoding="utf-8") if p.exists() else ""
    merged = OUT / "all.txt"
    merged.write_text("\n\n".join(v for v in parts.values() if v.strip()), encoding="utf-8")

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
