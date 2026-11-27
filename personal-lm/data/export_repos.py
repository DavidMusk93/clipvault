#!/usr/bin/env python3
"""D0h: 个人仓库思考沉淀 → corpus/repos.txt（用户指定：fleet-ops / flowkit / recallfs）。

范围 = md/txt 文档（思考/设计/决策沉淀），排除构建产物/依赖/临时目录；
secret 清洗复用 common（fleet-ops 有 hosts/conf 等敏感文件，行级过滤兜底）。

用法: .venv/bin/python data/export_repos.py [--force]
增量: watermark repos_hashes（路径+mtime+size 摘要）。
"""
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DOC_SEPARATOR, clean_text, docs_to_corpus, is_promising, now_iso

OUT = Path(__file__).resolve().parent.parent / "corpus"
WATERMARK = OUT / "watermark.json"

REPOS = [
    Path.home() / "Documents/01_Projects/fleet-ops",
    Path.home() / "Documents/01_Projects/flowkit",
    Path.home() / "Documents/trae_projects/recallfs",
]
EXCLUDE_DIRS = {"node_modules", ".build", ".tmp", "target", ".git", ".venv",
                "__pycache__", "dist", "vendor", ".pi", ".next", "checkpoints",
                "exports", "corpus", "hf-cache"}
EXCLUDE_SUFFIX = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".woff2", ".woff",
                  ".bin", ".safetensors", ".ckpt", ".zip", ".tar", ".gz", ".db",
                  ".sqlite3", ".log", ".svg"}
SKIP_NAME = {"id_rsa", ".env", "secret", "credentials", "token"}


def iter_docs(root: Path):
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.suffix.lower() in EXCLUDE_SUFFIX:
            continue
        if any(part in EXCLUDE_DIRS for part in p.parts):
            continue
        if any(s in p.name.lower() for s in SKIP_NAME):
            continue
        if p.suffix.lower() in (".md", ".markdown", ".txt", "") and p.stat().st_size < 300_000:
            yield p


def fingerprint(p: Path) -> str:
    st = p.stat()
    return hashlib.md5(f"{p}|{st.st_mtime_ns}|{st.st_size}".encode()).hexdigest()


def export(incremental: bool = True) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    wm = json.loads(WATERMARK.read_text()) if WATERMARK.exists() else {}
    seen = dict(wm.get("repos_hashes", {}))

    stats = {"scanned": 0, "new": 0, "skipped": 0, "too_short": 0}
    new_docs, new_fps = [], []
    for root in REPOS:
        if not root.exists():
            stats.setdefault("missing", []).append(str(root))
            continue
        for p in iter_docs(root):
            stats["scanned"] += 1
            fp = fingerprint(p)
            if incremental and seen.get(str(p)) == fp:
                stats["skipped"] += 1
                continue
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            text = clean_text(text)
            if not is_promising(text, 40):
                stats["too_short"] += 1
                continue
            rel = str(p).replace(str(Path.home()), "~")
            new_docs.append(f"## {rel}\n\n{text}")
            new_fps.append((str(p), fp))
            stats["new"] += 1

    repos_txt = OUT / "repos.txt"
    old = repos_txt.read_text(encoding="utf-8") if repos_txt.exists() else ""
    # 增量：旧文档里被更新过的路径要替换掉（按标题前缀匹配）
    old_docs = [d for d in old.split(DOC_SEPARATOR) if d.strip()]
    updated_paths = {str(p) for p, _ in new_fps}
    kept = [d for d in old_docs if not any(d.startswith(f"## {up}\n") for up in updated_paths)]
    repos_txt.write_text(docs_to_corpus(kept + new_docs), encoding="utf-8")

    seen.update(dict(new_fps))
    wm["repos_hashes"] = seen
    wm["repos_updated_at"] = now_iso()
    WATERMARK.write_text(json.dumps(wm, ensure_ascii=False, indent=1))
    stats["total_docs"] = len(kept) + len(new_docs)
    stats["bytes"] = repos_txt.stat().st_size
    return stats


if __name__ == "__main__":
    print(json.dumps(export(incremental="--force" not in sys.argv),
                     ensure_ascii=False, indent=1, default=str))
