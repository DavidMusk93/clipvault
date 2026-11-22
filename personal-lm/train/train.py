#!/usr/bin/env python3
"""D2: personal-lm 训练循环（MPS / CPU，单文件）。

用法：
  .venv/bin/python train/train.py --steps 3000          # 从头训练
  .venv/bin/python train/train.py --resume-latest       # 增量续训（warm start）
  .venv/bin/python train/train.py --max-steps 30        # sanity run

checkpoint: checkpoints/ckpt_latest.pt（每 250 步 + 结束时）
日志: checkpoints/train_log.jsonl
"""
import argparse
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from model import GPT

ROOT = HERE.parent
TOKENS_BIN = ROOT / "corpus" / "tokens.bin"
TOKENIZER_JSON = ROOT / "corpus" / "tokenizer.json"
CKPT_DIR = ROOT / "checkpoints"
LOG = CKPT_DIR / "train_log.jsonl"


def get_batch(data: np.ndarray, block: int, batch: int, device: str, rng: np.random.Generator):
    ix = rng.integers(0, len(data) - block - 1, size=batch)
    x = np.stack([data[i : i + block] for i in ix])
    y = np.stack([data[i + 1 : i + block + 1] for i in ix])
    to = lambda a: torch.from_numpy(a.astype(np.int64)).to(device)
    return to(x), to(y)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--block", type=int, default=512)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--warmup", type=int, default=100)
    ap.add_argument("--eval-every", type=int, default=250)
    ap.add_argument("--ckpt-every", type=int, default=250)
    ap.add_argument("--resume-latest", action="store_true")
    ap.add_argument("--max-steps", type=int, default=0, help="sanity run 上限")
    ap.add_argument("--tokens", default=str(TOKENS_BIN), help="token 流文件（v2 加权用 tokens_weighted.bin）")
    ap.add_argument("--device", default="auto", help="auto|cuda|mps|cpu")
    ap.add_argument("--layers", type=int, default=8)
    ap.add_argument("--d-model", type=int, default=384)
    ap.add_argument("--heads", type=int, default=6)
    ap.add_argument("--bf16", action="store_true", help="MPS bf16 autocast（实测比 fp32 慢，默认关）")
    args = ap.parse_args()

    CKPT_DIR.mkdir(parents=True, exist_ok=True)
    if args.device == "auto":
        device = "cuda" if torch.cuda.is_available() else (
            "mps" if torch.backends.mps.is_available() else "cpu")
    else:
        device = args.device

    data = np.memmap(args.tokens, dtype=np.uint16, mode="r")
    n_val = max(1000, len(data) // 100)
    val_data, train_data = data[-n_val:], data[:-n_val]
    print(f"[train] tokens: train={len(train_data):,} val={len(val_data):,} device={device}")

    tok_meta = json.loads(TOKENIZER_JSON.read_text())
    vocab_size = len(tok_meta["vocab"])

    model = GPT(vocab_size=vocab_size, block_size=args.block,
                n_layer=args.layers, d_model=args.d_model, n_head=args.heads)
    model.to(device)
    print(f"[train] params: {model.num_params()/1e6:.1f}M")

    step0 = 0
    if args.resume_latest:
        ck = CKPT_DIR / "ckpt_latest.pt"
        if ck.exists():
            payload = torch.load(ck, map_location=device, weights_only=False)
            model.load_state_dict(payload["model"])
            step0 = payload["step"]
            print(f"[train] resumed ckpt @ step {step0}")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, betas=(0.9, 0.95), weight_decay=0.1)
    if args.resume_latest and (CKPT_DIR / "ckpt_latest.pt").exists():
        payload = torch.load(CKPT_DIR / "ckpt_latest.pt", map_location=device, weights_only=False)
        if "opt" in payload:
            opt.load_state_dict(payload["opt"])

    total_steps = args.steps
    rng = np.random.default_rng(1337)
    use_bf16 = args.bf16 or (device == "cuda")  # CUDA 上默认开 bf16（快 3-5x）；
    # T4 等 bf16 不支持的卡自动回退 fp16（下方 autocast dtype 决定）
    amp_dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    scaler = torch.amp.GradScaler("cuda", enabled=(device == "cuda" and amp_dtype == torch.float16))
    t0 = time.time()

    @torch.no_grad()
    def eval_val() -> float:
        model.eval()
        losses = []
        for _ in range(8):
            xb, yb = get_batch(val_data, args.block, args.batch, device, rng)
            with torch.autocast(device, dtype=amp_dtype, enabled=use_bf16):
                _, loss = model(xb, yb)
            losses.append(loss.item())
        model.train()
        return sum(losses) / len(losses)

    if step0 > 0:
        print(f"[train] val@resume {eval_val():.4f}")

    model.train()
    logf = LOG.open("a")
    for step in range(step0, total_steps):
        # cosine + warmup
        lr = args.lr
        if step < args.warmup:
            lr = args.lr * (step + 1) / args.warmup
        else:
            p = (step - args.warmup) / max(1, total_steps - args.warmup)
            lr = args.lr * (0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(p, 1.0))))
        for g in opt.param_groups:
            g["lr"] = lr

        xb, yb = get_batch(train_data, args.block, args.batch, device, rng)
        with torch.autocast(device, dtype=amp_dtype, enabled=use_bf16):
            _, loss = model(xb, yb)
        opt.zero_grad(set_to_none=True)
        if scaler.is_enabled():
            scaler.scale(loss).backward()
            scaler.unscale_(opt)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            scaler.step(opt)
            scaler.update()
        else:
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()

        if step % 10 == 0 or step == total_steps - 1:
            dt = time.time() - t0
            tps = (step - step0 + 1) * args.batch * args.block / max(dt, 1e-6)
            msg = {"step": step, "loss": round(loss.item(), 4), "lr": round(lr, 6),
                   "tok/s": int(tps)}
            print(f"[train] step {step}/{total_steps} loss {msg['loss']} "
                  f"lr {msg['lr']} {msg['tok/s']} tok/s", flush=True)
            logf.write(json.dumps(msg) + "\n")
            logf.flush()

        if (step + 1) % args.eval_every == 0 or step == total_steps - 1:
            v = eval_val()
            print(f"[train] val loss {v:.4f} (ppl {math.exp(v):.1f})", flush=True)
            logf.write(json.dumps({"step": step, "val": round(v, 4)}) + "\n")
            logf.flush()

        if (step + 1) % args.ckpt_every == 0 or step == total_steps - 1:
            torch.save({"model": model.state_dict(), "opt": opt.state_dict(),
                        "step": step + 1, "config": model.config,
                        "tokenizer": str(TOKENIZER_JSON)},
                       CKPT_DIR / "ckpt_latest.pt")

    print(f"[train] done in {(time.time()-t0)/60:.1f} min → {CKPT_DIR/'ckpt_latest.pt'}")


if __name__ == "__main__":
    main()
