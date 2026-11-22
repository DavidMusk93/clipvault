# kaggle — 无人值守 GPU 训练（真正的"CLI 接管"）

Colab 没有官方执行 API（Pro 的后台执行也只是浏览器关掉继续跑，仍需 UI 触发）。
**Kaggle 才有官方 CLI/API**（同为 Google 系，30h/周免费 GPU：P100 / T4×2）。

## 一次性准备（2 分钟）

1. 登录 kaggle.com（可用 Google 账号登录）→ Settings → API → **Create New Token**
   → 下载 `kaggle.json`
2. 放到本机：`mkdir -p ~/.kaggle && mv ~/Downloads/kaggle.json ~/.kaggle/ && chmod 600 ~/.kaggle/kaggle.json`

## 之后全部由我接管

```sh
cd personal-lm/kaggle
./kaggle_run.sh gpt    # 98M 从零 GPT：建数据集 → 推内核 → 监控 → 拉回 bundle
./kaggle_run.sh qwen   # Qwen3-1.7B QLoRA：同上，产出 merge 模型
./kaggle_run.sh status # 查看内核状态
```

- 数据集 = `cloud_bundle.tar.gz`（tokens_weighted + tokenizer + lora jsonl，35MB，**private dataset**）
- 产出经 kernel output 下载 → `personal-lm/exports/` → 部署到 Keepsake
- 免费额度 30h/周，两个任务 ≈ 4-6h GPU，绰绰有余

## 文件

- `gpt_kernel.py` / `gpt_kernel-metadata.json` — 98M GPT 训练内核
- `qwen_kernel.py` / `qwen_kernel-metadata.json` — Qwen3-1.7B unsloth QLoRA 内核
- `kaggle_run.sh` — 数据集创建 + 内核推送 + 状态监控 + 产物回拉
