# personal-lm — ClipVault 个人小模型

为 ClipVault 训练/部署**个人专属小模型**（27M 参数 decoder-only GPT），
支撑两个产品功能：

1. **打字自动补全** — 笔记编辑器 ghost text（防抖 260ms，Tab 接受）
2. **个人风格生成** — `⌘⇧G` 按主题生成个人文风初稿

设计稿：`../docs/designs/feature-personal-lm.md`
隐私铁律：`PRIVACY.md` —— **语料/模型产物绝不入 git、绝不上传公共 Hub**。

## 一次迭代闭环（内容增长 → 模型跟进）

```sh
cd personal-lm
./iterate.sh            # 增量导出 → 续训(warm start) → eval → bundle → 热加载
./iterate.sh --full     # 全量重建从头训
```

产物链：`corpus/`（私有）→ `checkpoints/ckpt_latest.pt` → `exports/<version>/` →
`~/Library/Application Support/Keepsake/models/personal-lm/`（cv-lm 从这里加载）。

## 服务与 applet 接入

```sh
# LaunchAgent（推荐，开机自启）
cp LaunchAgents/com.davidmusk.clipvault-lm.plist ~/Library/LaunchAgents/  # 先替换 <user>
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.davidmusk.clipvault-lm.plist

# 或手动
~/Library/Application\ Support/Keepsake/bin/cv-lm serve   # 127.0.0.1:8788
```

API（仅绑定本机，CORS 已放行 ClipVault UI）：

| 路由 | 说明 |
| --- | --- |
| `GET /health` | `{status, version}` |
| `POST /complete` `{"prefix": "...", "max_tokens": 24}` | 补全（贪心，遇行止） |
| `POST /compose` `{"prompt": "...", "max_tokens": 256, "temperature": 0.8}` | 风格续写 |

CLI：`cv-lm complete "prefix" [--max-tokens 24] [--no-stop]`

其他 applet 两种接法：
1. **HTTP**：`curl 127.0.0.1:8788/complete ...`（零依赖）
2. **库**：`cvlm-core = { path = "../clipvault/personal-lm/rust/cvlm-core" }`
   ```rust
   let eng = cvlm_core::Engine::load(&bundle_dir)?;
   let text = eng.generate(prefix, &GenParams { max_tokens: 24, ..Default::default() })?;
   ```

## 技术栈与训练事实

| 项 | 值 |
| --- | --- |
| 语料 | clipflow.db（text/note/compose/OCR/批注）+ nmem 全部 memories ≈ **21.8M 字符** |
| Tokenizer | 从零 byte-level BPE，vocab 16384，中文 ≈1.4 字/token（pair-index + lazy heap，7 秒训完） |
| 模型 | GPT-2 风格：8 层 · d=384 · 6 heads · ctx 512 · **27M 参数** |
| 训练 | MPS (M1 Pro)，fp32，~13.5k tok/s，3000 步 ≈ 49M tokens ≈ 5 epochs，~65 分钟 |
| 推理 | Rust + candle 0.11 (Metal)，**与 PyTorch 前向数值验证一致** |
| 部署 | cv-lm serve（独立进程，manifest mtime 热加载） |
| 环境管理 | uv + `.venv`（CPython 3.12 + torch 2.15 + regex + safetensors） |

## 目录

```
personal-lm/
  data/          export_clipflow.py · export_nmem.py · build_corpus.py · common.py(secret 过滤)
  train/         tokenizer.py · model.py · train.py · export_bundle.py
  eval/          perplexity.py
  rust/          cvlm-core(库) + cv-lm(bin)  ← cargo build --release
  iterate.sh     一键增量迭代
  PRIVACY.md     隐私铁律（必读）
  corpus/ exports/ checkpoints/ .venv/   ← 全部 gitignored，私有
```
