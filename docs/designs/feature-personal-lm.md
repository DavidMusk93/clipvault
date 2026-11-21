# feature-personal-lm — ClipVault 个人小模型：打字补全 & 个人风格生成（设计稿 v1）

状态：**设计稿（D0 未开始）**。真源上下文：nmem（训练/应用架构 ASCII 图见 nmem memory：`ClipVault personal-lm 训练与应用架构`）。

## 一句话结论

在 ClipVault 新增 `personal-lm/` 子项目：**从零实现**一个 ~20–50M 参数的 decoder-only 小模型（Python/PyTorch 单文件训练，Rust/candle 推理进 http-front），语料 = clipflow.db 全量文本 + nmem 历史 + agent 会话日志，支持从最新 checkpoint 增量续训（内容持续增长 → 模型持续迭代）。落地两个功能：编辑器 ghost-text **打字补全**、**个人风格**文稿/技术方案初稿生成。

## 期望管理（诚实边界）

| 能力 | 从零小模型能做到吗 | 对策 |
| --- | --- | --- |
| 个人文风/词汇/句式模仿 | ✅ 核心卖点 | 小模型预训练足够 |
| 打字补全（续写、领域词） | ✅ | KV cache + 前缀缓存 |
| 技术方案完整生成 | ⚠️ 推理弱 | 阶段 2：LoRA 微调 Qwen3-0.6B / SmolLM2-360M 作为"方案引擎"，本模型只出"个人风格初稿"；或 RAG 兜底 |
| 语料规模匹配 | ✅ 当前 ~3MB 纯文本（≈200–300 万 token，中文为主），专有小模型规模正确 | 随内容增长增量续训 |

## 参考项目（2026-11-21 GitHub 已核实）

| 项目 | 角色 |
| --- | --- |
| karpathy/nanochat | 端到端训练 harness 参考（nanoGPT 继任者：tokenize→pretrain→finetune→eval→inference） |
| karpathy/llm.c | 纯 C 训练参考（可选练习） |
| karpathy/minbpe | BPE tokenizer 从零实现参考 |
| ml-explore/mlx + mlx-lm | Apple Silicon 原生训练 / LoRA 微调（阶段 2 用） |
| huggingface/candle | 纯 Rust 推理框架 → **部署进 http-front，运行时零 Python** |
| ggml-org/llama.cpp | GGUF 部署备选 |
| huggingface/smollm | 阶段 2 微调底座备选（135M/360M/1.7B，开放语料） |

## 架构总图

### 1) 训练管道（offline，Mac 上跑）

```
 clipflow.db            nmem 历史             agent 会话日志         笔记/文档文件
 (text/ocr/note/     (nmem API/FS 导出)      (trae_hooks/cc-      (cc-notes 等)
  judgment)                                   notes)
     │                    │                     │                    │
     └────────┬───────────┴──────────┬──────────┴─────────┬──────────┘
              ▼                      ▼                    ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ personal-lm/data/  exporters → corpus/                       │
   │   去重(clip 相同 hash 只留一条) · 清洗 · 按来源分段标注          │
   └───────────────────────────┬──────────────────────────────────┘
                               ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ personal-lm/train/tokenizer.py   自训 BPE vocab ~16k          │
   │   (minbpe 式从零实现，bytes 级，中文 3 bytes/字自动可学)          │
   └───────────────────────────┬──────────────────────────────────┘
                               ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ personal-lm/train/model.py + train.py                        │
   │   decoder-only GPT: 8–12 层 · d=512 · ~20–50M 参数             │
   │   device = MPS (Mac) · 单文件训练脚本                          │
   │   ckpt v1 ──warm start──▶ ckpt v2 ──▶ ...  (增量续训)          │
   └───────────────────────────┬──────────────────────────────────┘
                               ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ export → model.safetensors + tokenizer.json + config.json     │
   │          (版本号 = 训练日期 + 语料版本)                         │
   └───────────────────────────┬──────────────────────────────────┘
                               ▼  (复制到 CLIPVAULT_HOME/models/)
                        部署（见下图 2）
```

### 2) 应用架构（实施修订版：`cv-lm serve` 独立加载器）

> **实施决策（2026-11-22）**：浏览器日常入口是 Swift ClipVaultServer `:8080`
> （http-front `:80/:443` 未在日常路径上）。推理引擎改为独立进程
> **`cv-lm serve`（127.0.0.1:8788，LaunchAgent）**：Web UI 与其他 applet 都直接
> 调它（CORS 已开），http-front 保持零改动。bundle 支持热加载（manifest mtime）。

```
 web 编辑器 (notes-editor entry.js)          其他 applet (recallfs/*)
   │  打字… 防抖 260ms                            │
   ▼                                             ▼
 POST /complete {prefix}        POST /complete|/compose（CLI: cv-lm complete）
   │                                             │
   └───────────────────┬──────────────────────────┘
                       ▼
   ┌─────────────────────────────────────────────┐
   │ cv-lm serve  (127.0.0.1:8788, LaunchAgent)  │
   │  └─ cvlm-core (Rust/candle, metal)          │
   │      ├─ bundle: config+tokenizer+safetensors │
   │      │    ← CLIPVAULT_HOME/models/personal-lm│
   │      ├─ 自实现 transformer 前向（同 Python）  │
   │      └─ 热加载: manifest.json mtime 变更即重载 │
   └─────────────────────────────────────────────┘
                       │
                       ▼
   ghost text（灰色，Tab 接受） / 风格初稿（Mod-Shift-g）
```

### 3) 迭代闭环（内容增长 → 模型跟进）

```
 日常使用: clip + note + nmem 记忆持续增长
        │
        ▼ (定期或手动触发)
 exporter 增量导出 (自上次 watermark) ──▶ corpus vN+1
        │
        ▼
 续训: load ckpt vN ──train──▶ ckpt vN+1
        │
        ▼
 eval: held-out 困惑度 + 补全样例人工抽检
        │  通过
        ▼
 safetensors vN+1 ──▶ CLIPVAULT_HOME/models/ ──▶ http-front 热加载
        │
        ▼
 产品内两个功能自动升级，无需重启 daemon
```

## 分阶段实施

| 阶段 | 内容 | 产出 |
| --- | --- | --- |
| D0 | `data/export_clipflow.py`（db→corpus）+ `data/export_nmem.py` | 语料管道 |
| D1 | `train/tokenizer.py` 自训 BPE（vocab ~16k） | tokenizer.json |
| D2 | `train/model.py` + `train/train.py` 从零 GPT，MPS 训练 | ckpt + 困惑度基线 |
| D3 | `http-front` 内 candle 推理模块 + `/api/lm/*` 路由 | 本地推理可用 |
| D4 | Web UI：编辑器 ghost text + compose 面板 | 两功能上线 |
| D5 | 增量续训脚本 + checkpoint 版本管理 + 热加载 | 迭代闭环 |
| D6（阶段 2） | mlx-lm LoRA 微调 Qwen3-0.6B/SmolLM2-360M 做"方案引擎"，与个人风格模型混合 | 技术方案生成 |

## 非目标

- 不做云端训练/云端推理（模型与语料全部留在本地，符合 local-first 产品法）。
- 不追求通用对话能力；不替代 nmem（nmem 是记忆中心，本模型是文风/补全引擎）。
- 阶段 1 不引入 GGUF（candle 直接读 safetensors，链路更短、更利于"从零理解架构"）。

## 目录骨架

```
personal-lm/
  README.md               # 训练/复现/迭代手册
  .gitignore              # checkpoints/ corpus/ 不入库
  data/
    export_clipflow.py    # clipflow.db → corpus/
    export_nmem.py        # nmem API → corpus/
  train/
    tokenizer.py          # BPE（minbpe 式从零实现）
    model.py              # transformer 定义
    train.py              # 单文件训练循环（MPS）
    export_safetensors.py
  eval/
    perplexity.py
```
