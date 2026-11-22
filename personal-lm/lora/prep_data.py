#!/usr/bin/env python3
"""LoRA 数据准备：加权语料 → mlx_lm.lora JSONL（{"text": doc}，5% 验证集）。"""
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
docs = [d.strip() for d in (ROOT / "corpus" / "all_weighted.txt").read_text(encoding="utf-8").split("<|doc|>") if d.strip()]
random.seed(7)
random.shuffle(docs)
n_val = max(50, len(docs) // 20)
with (ROOT / "lora" / "train.jsonl").open("w") as f:
    for d in docs[n_val:]:
        f.write(json.dumps({"text": d}, ensure_ascii=False) + "\n")
with (ROOT / "lora" / "valid.jsonl").open("w") as f:
    for d in docs[:n_val]:
        f.write(json.dumps({"text": d}, ensure_ascii=False) + "\n")
print(f"train={len(docs)-n_val} valid={n_val}")
