#!/usr/bin/env python3
"""D3a: checkpoint → 可移植 model bundle（其他 applet 可加载）。

bundle 布局（exports/<version>/）：
  manifest.json      # 格式声明 + 文件 sha256 + 训练统计
  config.json        # 模型结构 + 推理参数
  tokenizer.json     # BPE（personal-lm-bpe-v1）
  model.safetensors  # fp32 权重

铁律：bundle 是个人私有产物，只落本机（默认同时复制一份到
CLIPVAULT_HOME/models/personal-lm/），绝不入 git / 不上传公共 Hub。
"""
import hashlib
import json
import math
import shutil
import sys
from pathlib import Path

from safetensors.torch import save_file
import torch

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CKPT_DIR = ROOT / "checkpoints"
EXPORTS = ROOT / "exports"
TOKENIZER_JSON = ROOT / "corpus" / "tokenizer.json"
CLIPVAULT_HOME = Path.home() / "Library/Application Support/Keepsake"
DEPLOY_DIR = CLIPVAULT_HOME / "models" / "personal-lm"


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def latest_val() -> str:
    log = CKPT_DIR / "train_log.jsonl"
    if log.exists():
        vals = [json.loads(l) for l in log.read_text().splitlines() if '"val"' in l]
        if vals:
            return str(vals[-1]["val"])
    return "n/a"


def main():
    ck = CKPT_DIR / "ckpt_latest.pt"
    if not ck.exists():
        sys.exit("no checkpoint found; run train.py first")
    payload = torch.load(ck, map_location="cpu", weights_only=False)
    cfg = payload["config"]
    step = payload["step"]

    import time as _t
    version = f"v{step}-e{int(_t.time())}"  # e=export 时间戳：重导出也会换版本，保证 mac-work pull 能感知二进制更新
    out = EXPORTS / version
    out.mkdir(parents=True, exist_ok=True)

    # safetensors（fp32，保持 state_dict 键名，Rust 侧同名加载）
    sd = {k: v.to(torch.float32).contiguous() for k, v in payload["model"].items()}
    save_file(sd, out / "model.safetensors", metadata={"format": "pt"})

    config = {
        "format": "personal-lm-bundle-v1",
        "version": version,
        "model": cfg,                     # vocab_size/block_size/n_layer/n_head/d_model
        "trained_steps": step,
        "val_loss": latest_val(),
        "tokenizer": "tokenizer.json",
        "notes": "个人私有模型；勿分发",
    }
    (out / "config.json").write_text(json.dumps(config, ensure_ascii=False, indent=1))
    shutil.copy(TOKENIZER_JSON, out / "tokenizer.json")
    retrieval_src = ROOT / "corpus" / "retrieval_lines.jsonl"
    if retrieval_src.exists():
        shutil.copy(retrieval_src, out / "retrieval_lines.jsonl")

    manifest = {
        "format": "personal-lm-bundle-v1",
        "version": version,
        "created": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        "files": {f.name: {"bytes": f.stat().st_size, "sha256": sha256(f)}
                  for f in sorted(out.iterdir()) if f.name != "manifest.json"},
        "private": True,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))

    # 部署副本 → CLIPVAULT_HOME/models/personal-lm（http-front / cv-lm 从这里加载）
    if DEPLOY_DIR.exists():
        shutil.rmtree(DEPLOY_DIR)
    shutil.copytree(out, DEPLOY_DIR)

    size_mb = sum(f.stat().st_size for f in out.iterdir()) / 1e6
    print(json.dumps({"bundle": str(out), "deployed_to": str(DEPLOY_DIR),
                      "version": version, "steps": step,
                      "val_loss": latest_val(), "size_MB": round(size_mb, 1)},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
