# personal-lm — ClipVault 个人小模型

为 ClipVault 训练/部署一个**个人专属小模型**（~20–50M 参数 decoder-only），
支撑两个产品功能：

1. **打字自动补全** — 编辑器 ghost text（续写、个人词汇、领域词）
2. **个人风格生成** — 按我的文风出文稿/技术方案初稿

设计稿：`../docs/designs/feature-personal-lm.md`
ASCII 架构图真源：nmem（搜 "ClipVault personal-lm 训练与应用架构"）。

## 训练 / 部署框架一览

| 环节 | 选型 | 理由 |
| --- | --- | --- |
| Tokenizer | 自训 BPE（minbpe 式，vocab ~16k） | 从零理解；bytes 级对中文友好 |
| 训练 | 单文件 PyTorch（nanoGPT 风格），device=MPS | Mac Apple Silicon 上直接跑；教学价值最大 |
| 参考实现 | karpathy/nanochat（nanoGPT 继任者）、minbpe | 最可读的端到端 harness |
| 推理 | Rust + huggingface/candle，进 `http-front` sidecar | 运行时零 Python，与现有架构契合 |
| 推理备选 | ggml-org/llama.cpp (GGUF) | 若 candle 自实现前向成本过高时切换 |
| 阶段2 方案引擎 | ml-explore/mlx-lm LoRA 微调 Qwen3-0.6B / SmolLM2-360M | 小模型负责文风，微调底座负责推理 |

## 语料源

- `~/Library/Application Support/Keepsake/clipflow.db`
  → `clipboard_items.text_content / ocr_text / user_note / judgment_text`
- nmem 历史（via nmem API 导出）
- agent 会话日志（trae_hooks / cc-notes）

## 阶段（对应设计稿 D0–D6）

```
D0 export ─▶ D1 tokenizer ─▶ D2 train(MPS) ─▶ D3 candle 推理进 http-front
                                      │
                                      ▼
                              D4 web UI (ghost text / compose)
                                      │
                                      ▼
                       D5 增量续训闭环 ─▶ D6 LoRA 方案引擎
```

## 使用（D0 后逐步补充）

```sh
# 导出语料
python3 data/export_clipflow.py
# 训练 tokenizer
python3 train/tokenizer.py train --corpus corpus/all.txt
# 训练模型（增量续训自动 warm start 最新 ckpt）
python3 train/train.py --resume-latest
```
