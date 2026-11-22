#!/usr/bin/env python3
"""补全质量评测（v2 战役的准绳）。

从 compose_ops 最新版本（真实打字面）构造 held-out 基准：
  prefix = 文档前 40%（≤200 字符）→ gold = 其后 60 字符
查询 cv-lm HTTP（默认 :8788），指标：
  - exact:   补全与 gold 前 20 字符（归一空白后）一致
  - match4:  前 4 个 BPE token 一致
  - lcp:     最长公共前缀 / len(gold)（字符级）
输出 JSON 落盘（--out），可跨版本对比。

用法:
  .venv/bin/python eval/autocomplete.py --out eval/auto_baseline.json [--port 8788]
"""
import argparse
import json
import sqlite3
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "train"))
from tokenizer import BPETokenizer  # noqa: E402

ROOT = HERE.parent
TOKENIZER_JSON = ROOT / "corpus" / "tokenizer.json"
DB = Path.home() / "Library/Application Support/Keepsake/clipflow.db"


def build_cases(n: int = 60):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    rows = con.execute(
        """SELECT body FROM compose_ops c
           WHERE ts = (SELECT MAX(ts) FROM compose_ops c2 WHERE c2.item_id = c.item_id)
           ORDER BY ts DESC LIMIT ?""",
        (n,),
    ).fetchall()
    con.close()
    cases = []
    for (body,) in rows:
        text = (body or "").strip()
        if len(text) < 120:
            continue
        cut = min(200, max(40, int(len(text) * 0.4)))
        # 在换行处切，贴近真实打字场景
        nl = text.find("\n", cut)
        cut = nl + 1 if 0 < nl < cut + 80 else cut
        prefix, gold = text[:cut], text[cut:cut + 60].strip()
        if not gold:
            continue
        cases.append({"prefix": prefix, "gold": gold})
    return cases


def norm(s: str) -> str:
    return "".join(s.split())


def lcp_ratio(a: str, b: str) -> float:
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    return i / max(1, len(b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--max-tokens", type=int, default=32)
    args = ap.parse_args()

    tok = BPETokenizer.load(TOKENIZER_JSON)
    cases = build_cases()
    print(f"[eval] {len(cases)} cases")

    exact = m4 = 0
    lcps = []
    per = []
    for c in cases:
        req = urllib.request.Request(
            f"http://127.0.0.1:{args.port}/complete",
            data=json.dumps({"prefix": c["prefix"], "max_tokens": args.max_tokens}).encode(),
            headers={"content-type": "application/json"},
        )
        try:
            d = json.loads(urllib.request.urlopen(req, timeout=60).read())
            comp = d.get("completion", "")
        except Exception as e:  # noqa: BLE001
            comp = ""
            per.append({**c, "completion": f"<ERR {e}>"})
            continue
        ng, nc = norm(c["gold"]), norm(comp)
        e = ng[:20] == nc[:20] and len(nc) > 0
        g4 = tok.encode(c["gold"])[:4]
        c4 = tok.encode(comp)[:4]
        m = g4 == c4 and len(c4) > 0
        exact += e
        m4 += m
        lcps.append(lcp_ratio(nc, ng))
        per.append({**c, "completion": comp, "exact": e, "match4": m,
                    "lcp": round(lcp_ratio(nc, ng), 3)})

    out = {
        "cases": len(cases),
        "exact_rate": round(exact / len(cases), 4),
        "match4_rate": round(m4 / len(cases), 4),
        "lcp_mean": round(sum(lcps) / len(lcps), 4),
    }
    (ROOT / args.out).write_text(
        json.dumps({"summary": out, "per_case": per}, ensure_ascii=False, indent=1)
    )
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
