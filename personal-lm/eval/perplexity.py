#!/usr/bin/env python3
"""D2b: held-out 困惑度评估（ckpt 的 val loss → ppl）。

用法: .venv/bin/python eval/perplexity.py [--ckpt checkpoints/ckpt_latest.pt]
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "train"))
from model import GPT

ROOT = HERE.parent
TOKENS_BIN = ROOT / "corpus" / "tokens.bin"
TOKENIZER_JSON = ROOT / "corpus" / "tokenizer.json"


@torch.no_grad()
def main():
    ck_path = ROOT / "checkpoints" / "ckpt_latest.pt"
    payload = torch.load(ck_path, map_location="mps", weights_only=False)
    cfg = payload["config"]
    model = GPT(vocab_size=cfg["vocab_size"], block_size=cfg["block_size"],
                n_layer=cfg["n_layer"], n_head=cfg["n_head"], d_model=cfg["d_model"]).to("mps")
    model.load_state_dict(payload["model"])
    model.eval()

    data = np.memmap(TOKENS_BIN, dtype=np.uint16, mode="r")
    n_val = max(1000, len(data) // 100)
    val = data[-n_val:]
    B, T = 16, cfg["block_size"]
    rng = np.random.default_rng(4242)
    losses = []
    for _ in range(20):
        ix = rng.integers(0, len(val) - T - 1, size=B)
        x = torch.from_numpy(np.stack([val[i:i+T] for i in ix]).astype(np.int64)).to("mps")
        y = torch.from_numpy(np.stack([val[i+1:i+T+1] for i in ix]).astype(np.int64)).to("mps")
        _, loss = model(x, y)
        losses.append(loss.item())
    l = sum(losses) / len(losses)
    out = {"ckpt_step": payload["step"], "val_loss": round(l, 4), "ppl": round(math.exp(l), 1),
           "val_tokens": int(n_val)}
    print(json.dumps(out, ensure_ascii=False))
    (ROOT / "checkpoints" / "eval.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
