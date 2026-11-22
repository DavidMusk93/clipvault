# Kaggle kernel: personal-lm 从零 GPT 98M 训练（P100/T4 适配）
# 数据: kaggle dataset (private) cloud_bundle.tar.gz -> /kaggle/input/<dataset>/
# 产出: /kaggle/working/exports/<step>/ (model.safetensors + config + tokenizer)
import json, math, os, time, glob
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from pathlib import Path

DATA_DIR = Path("/kaggle/working/data")
OUT = Path("/kaggle/working/exports")
STEPS = int(os.environ.get("PL_STEPS", "6000"))
BATCH = int(os.environ.get("PL_BATCH", "32"))

# ---- 解包数据集 ----
zips = glob.glob("/kaggle/input/**/*.tar.gz", recursive=True)
assert zips, "cloud_bundle.tar.gz not found in dataset input"
os.system(f"mkdir -p {DATA_DIR} && tar -xzf '{zips[0]}' -C /kaggle/working && cp -r /kaggle/working/cloud/* {DATA_DIR}/")
print("data:", os.listdir(DATA_DIR))

# ---- 模型（与 personal-lm/train/model.py 完全同构）----
class CausalSelfAttention(nn.Module):
    def __init__(self, d, nh, drop=0.0):
        super().__init__()
        assert d % nh == 0
        self.nh, self.dh = nh, d // nh
        self.qkv = nn.Linear(d, 3 * d)
        self.proj = nn.Linear(d, d)
        self.drop = drop
        self.resid_drop = nn.Dropout(drop)
    def forward(self, x):
        B, T, C = x.shape
        q, k, v = self.qkv(x).split(C, dim=2)
        q = q.view(B, T, self.nh, self.dh).transpose(1, 2)
        k = k.view(B, T, self.nh, self.dh).transpose(1, 2)
        v = v.view(B, T, self.nh, self.dh).transpose(1, 2)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True)
        y = y.transpose(1, 2).contiguous().view(B, T, C)
        return self.resid_drop(self.proj(y))

class MLP(nn.Module):
    def __init__(self, d, drop=0.0):
        super().__init__()
        self.fc = nn.Linear(d, 4 * d)
        self.proj = nn.Linear(4 * d, d)
        self.drop = nn.Dropout(drop)
    def forward(self, x):
        return self.drop(self.proj(F.gelu(self.fc(x))))

class Block(nn.Module):
    def __init__(self, d, nh):
        super().__init__()
        self.ln1 = nn.LayerNorm(d)
        self.attn = CausalSelfAttention(d, nh)
        self.ln2 = nn.LayerNorm(d)
        self.mlp = MLP(d)
    def forward(self, x):
        x = x + self.attn(self.ln1(x))
        x = x + self.mlp(self.ln2(x))
        return x

class GPT(nn.Module):
    def __init__(self, vocab, block, n_layer, n_head, d_model):
        super().__init__()
        self.block_size = block
        self.config = dict(vocab_size=vocab, block_size=block, n_layer=n_layer,
                           n_head=n_head, d_model=d_model)
        self.tok_emb = nn.Embedding(vocab, d_model)
        self.pos_emb = nn.Embedding(block, d_model)
        self.drop = nn.Dropout(0.0)
        self.blocks = nn.ModuleList([Block(d_model, n_head) for _ in range(n_layer)])
        self.ln_f = nn.LayerNorm(d_model)
        self.head = nn.Linear(d_model, vocab, bias=False)
        self.apply(self._init)
    def _init(self, m):
        if isinstance(m, nn.Linear):
            nn.init.normal_(m.weight, 0.0, 0.02)
            if m.bias is not None: nn.init.zeros_(m.bias)
        elif isinstance(m, nn.Embedding):
            nn.init.normal_(m.weight, 0.0, 0.02)
    def forward(self, idx, targets=None):
        B, T = idx.shape
        pos = torch.arange(T, device=idx.device)
        x = self.drop(self.tok_emb(idx) + self.pos_emb(pos))
        for blk in self.blocks: x = blk(x)
        x = self.ln_f(x)
        logits = self.head(x)
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss
    def num_params(self):
        return sum(p.numel() for p in self.parameters())

def get_batch(data, block, batch, device, rng):
    ix = rng.integers(0, len(data) - block - 1, size=batch)
    x = np.stack([data[i:i+block] for i in ix])
    y = np.stack([data[i+1:i+block+1] for i in ix])
    to = lambda a: torch.from_numpy(a.astype(np.int64)).to(device)
    return to(x), to(y)

def main():
    device = "cuda"
    data = np.memmap(DATA_DIR / "tokens_weighted.bin", dtype=np.uint16, mode="r")
    n_val = max(1000, len(data) // 100)
    val, train = data[-n_val:], data[:-n_val]
    tok = json.loads((DATA_DIR / "tokenizer.json").read_text())
    vocab = len(tok["vocab"])
    model = GPT(vocab, 512, 12, 12, 768).to(device)
    print(f"params: {model.num_params()/1e6:.1f}M | train tokens: {len(train):,} | gpu: {torch.cuda.get_device_name(0)}")
    opt = torch.optim.AdamW(model.parameters(), lr=6e-4, betas=(0.9, 0.95), weight_decay=0.1)
    amp_dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    scaler = torch.amp.GradScaler("cuda", enabled=(amp_dtype == torch.float16))
    rng = np.random.default_rng(1337)
    warmup = 200
    t0 = time.time()
    for step in range(STEPS):
        lr = 6e-4 * (step + 1) / warmup if step < warmup else \
             6e-4 * (0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(1.0, (step - warmup) / max(1, STEPS - warmup)))))
        for g in opt.param_groups: g["lr"] = lr
        xb, yb = get_batch(train, 512, BATCH, device, rng)
        with torch.autocast("cuda", dtype=amp_dtype):
            _, loss = model(xb, yb)
        opt.zero_grad(set_to_none=True)
        if scaler.is_enabled():
            scaler.scale(loss).backward()
            scaler.unscale_(opt)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            scaler.step(opt); scaler.update()
        else:
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
        if step % 100 == 0 or step == STEPS - 1:
            tps = (step + 1) * BATCH * 512 / max(time.time() - t0, 1e-6)
            print(f"step {step}/{STEPS} loss {loss.item():.4f} {tps:,.0f} tok/s", flush=True)
        if (step + 1) % 500 == 0 or step == STEPS - 1:
            model.eval(); vl = []
            with torch.no_grad():
                for _ in range(8):
                    xb, yb = get_batch(val, 512, BATCH, device, rng)
                    with torch.autocast("cuda", dtype=amp_dtype):
                        _, l = model(xb, yb)
                    vl.append(l.item())
            model.train()
            v = sum(vl) / len(vl)
            print(f"val loss {v:.4f} (ppl {math.exp(v):.1f})", flush=True)
            torch.save({"model": model.state_dict(), "step": step + 1, "config": model.config},
                       "/kaggle/working/ckpt_cloud.pt")

    # ---- 导出 bundle ----
    from safetensors.torch import save_file
    payload = torch.load("/kaggle/working/ckpt_cloud.pt", map_location="cpu", weights_only=False)
    out = OUT / f"v{payload['step']}"
    out.mkdir(parents=True, exist_ok=True)
    sd = {k: vv.to(torch.float32).contiguous() for k, vv in payload["model"].items()}
    save_file(sd, out / "model.safetensors", metadata={"format": "pt"})
    (out / "config.json").write_text(json.dumps({
        "format": "personal-lm-bundle-v1", "version": f"v{payload['step']}-kaggle",
        "model": payload["config"], "trained_steps": payload["step"],
        "tokenizer": "tokenizer.json", "notes": "个人私有模型；勿分发"}, ensure_ascii=False, indent=1))
    import shutil
    shutil.copy(DATA_DIR / "tokenizer.json", out / "tokenizer.json")
    (out / "manifest.json").write_text(json.dumps({"version": f"v{payload['step']}-kaggle", "private": True}))
    print("bundle ->", out)

if __name__ == "__main__":
    main()
