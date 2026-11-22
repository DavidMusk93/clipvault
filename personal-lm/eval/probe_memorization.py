#!/usr/bin/env python3
"""记忆探针：语料文档给前半当 prompt，看模型能否复现后半。
复现率 = 前 30 字符归一重合比例 ≥ 0.8 的比例。回答"数据到底训进去没有"。
用法: probe_memorization.py --engine local|qwen [--n 100]
  local: 需一个不带 CVLM_COMPLETE_BACKEND 的 cv-lm（脚本自动起 :8793）
  qwen : mlx server :8790
"""
import argparse, json, os, random, signal, subprocess, sys, time, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "data"))

def norm(s): return "".join(s.split())

def lcp(a, b):
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    return i / max(1, min(30, len(b) or 1))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=["local", "qwen"], required=True)
    ap.add_argument("--n", type=int, default=100)
    args = ap.parse_args()

    text = (ROOT / "corpus" / "all.txt").read_text(encoding="utf-8")
    docs = [d.strip() for d in text.split("<|doc|>") if len(d.strip()) > 120]
    random.seed(11)
    docs = random.sample(docs, args.n)

    port = 8793 if args.engine == "local" else 8790
    if args.engine == "local":
        env = dict(os.environ); env.pop("CVLM_COMPLETE_BACKEND", None)
        p = subprocess.Popen([str(ROOT / "rust/target/release/cv-lm"), "serve", "--port", "8793",
                              "--bundle", os.path.expanduser("~/Library/Application Support/Keepsake/models/personal-lm")],
                             env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             preexec_fn=os.setsid)
        time.sleep(2)
    try:
        n_ok = 0
        lcs = []
        for d in docs:
            cut = len(d) // 2
            # gold = cut 后第一行的前 30 字（与补全语义对齐：ghost 是单行）
            rest = d[cut:].strip()
            gold_line = rest.split("\n")[0][:30] if rest else ""
            prompt, gold = d[:cut], norm(gold_line)
            try:
                if args.engine == "local":
                    req = urllib.request.Request(f"http://127.0.0.1:8793/complete",
                        data=json.dumps({"prefix": prompt, "max_tokens": 40}).encode(),
                        headers={"content-type": "application/json"})
                    comp = json.loads(urllib.request.urlopen(req, timeout=120).read()).get("completion", "")
                else:
                    req = urllib.request.Request("http://127.0.0.1:8790/v1/completions",
                        data=json.dumps({"prompt": prompt, "max_tokens": 40, "temperature": 0.0}).encode(),
                        headers={"content-type": "application/json"})
                    comp = json.loads(urllib.request.urlopen(req, timeout=120).read())["choices"][0]["text"]
            except Exception as e:
                comp = f"<ERR>"
            ratio = lcp(norm(comp), gold)
            lcs.append(ratio)
            n_ok += ratio >= 0.8
        print(json.dumps({"engine": args.engine, "n": len(docs),
                          "recall_rate(前30字>=0.8)": round(n_ok/len(docs), 3),
                          "lcp_mean": round(sum(lcs)/len(lcs), 3)}, ensure_ascii=False))
    finally:
        if args.engine == "local":
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)

if __name__ == "__main__":
    main()
