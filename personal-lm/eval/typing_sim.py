#!/usr/bin/env python3
"""ghost 补全 UX smoke 探针（「及时发现体验劣化」的准绳）。

模拟真实打字：取最近一篇笔记，按固定步长递进输入，每步调 /complete，
按编辑器的过期丢弃规则（响应到达时前缀已变）统计 ghost 实际可见率。

指标（区别于 autocomplete.py 的正确率——那个测不出体验问题）：
  stale   = 响应晚于打字间隔被编辑器丢弃的比例  ← 「几乎不可用」的真凶
  empty   = 置信度门控拦截的比例
  shown   = 会真正显示的 ghost 比例（非空且及时）
  lat_p50/p95 = 端到端延迟

PASS/FAIL 门限（可用 --fail-stale/--fail-p95 调）：
  stale + empty > 40%  或  lat_p95 > 800ms  → FAIL（exit 1）

结果追加 JSONL 到 --out（默认 Keepsake/logs/cv-lm-ghost-smoke.jsonl），
供趋势观察；launchd 定时器每 30min 跑一次（com.davidmusk.clipvault-lm-smoke）。

用法:
  .venv/bin/python eval/typing_sim.py            # 单次探针
  .venv/bin/python eval/typing_sim.py --quiet    # 定时器模式（只输出一行结论）
"""
import argparse
import json
import sqlite3
import statistics
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def complete(url: str, prefix: str, max_tokens: int, timeout: float = 30.0):
    t0 = time.time()
    req = urllib.request.Request(
        f"{url}/complete",
        data=json.dumps({"prefix": prefix[-400:], "max_tokens": max_tokens}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    return d, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8788")
    ap.add_argument("--db", default=str(Path.home() / "Library/Application Support/Keepsake/clipflow.db"))
    ap.add_argument("--out", default=str(Path.home() / "Library/Application Support/Keepsake/logs/cv-lm-ghost-smoke.jsonl"))
    ap.add_argument("--interval", type=float, default=0.3, help="模拟打字间隔 s（编辑器丢弃阈值）")
    ap.add_argument("--step", type=int, default=6, help="每次前进字符数")
    ap.add_argument("--fail-stale", type=float, default=0.4, help="stale+empty 超过该比例 → FAIL")
    ap.add_argument("--fail-p95", type=float, default=800.0, help="p95 延迟 ms 超过 → FAIL")
    ap.add_argument("--max-tokens", type=int, default=16)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    row = con.execute(
        "SELECT text_content FROM clipboard_items WHERE type='note' AND deleted_at IS NULL "
        "ORDER BY timestamp DESC LIMIT 1"
    ).fetchone()
    con.close()
    text = (row[0] if row else "").strip()
    if len(text) < 120:
        print("SKIP: latest note too short", file=sys.stderr)
        return 2

    steps = list(range(40, min(len(text), 360), args.step))
    lat, srcs, empty, stale, shown = [], {}, 0, 0, 0
    for n in steps:
        d, dt = complete(args.url, text[:n], args.max_tokens)
        lat.append(dt)
        s = d.get("source", "other")
        srcs[s] = srcs.get(s, 0) + 1
        comp = (d.get("completion") or "").strip()
        if not comp:
            empty += 1
        else:
            shown += 1
            if dt > args.interval:
                stale += 1
                shown -= 1
    n = len(steps)
    p50 = statistics.median(lat) * 1000
    lat_sorted = sorted(lat)
    p95 = lat_sorted[max(0, int(len(lat) * 0.95) - 1)] * 1000
    bad_ratio = (stale + empty) / n
    ok = bad_ratio <= args.fail_stale and p95 <= args.fail_p95
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "steps": n, "sources": srcs, "empty": empty, "stale": stale,
        "shown": shown, "lat_p50_ms": round(p50), "lat_p95_ms": round(p95),
        "bad_ratio": round(bad_ratio, 3), "pass": ok,
        "note_len": len(text),
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    line = (f"[ghost-smoke] {'PASS' if ok else 'FAIL'} shown={shown}/{n} "
            f"stale={stale} empty={empty} p50={p50:.0f}ms p95={p95:.0f}ms "
            f"srcs={srcs} → {args.out}")
    print(line if args.quiet else json.dumps(rec, ensure_ascii=False, indent=1) + f"\n{line}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
