# colab — 云端 GPU 训练（Google Colab + Drive）

> 决策记录（2026-11-22）：用户明确同意"数据落在 Google Drive，一切云上方式"。
> 此前的"绝不落云"铁律据此修订为：**语料/模型只进用户自己信任的存储
> （Drive / ostore），仍然绝不进 git / 公共 Hub**。

## 三条路的真相（2026-11-22 核实）

| 路径 | 算力来源 | CLI 化 | 代价 |
| --- | --- | --- | --- |
| **消费版 Colab（Pro 会员）** | Pro 算力池（T4/A100/L4） | ❌ 官方无执行 API | 你开浏览器点 Run all；watcher 模式下只开一次 |
| **Colab Enterprise（gcloud colab）** | GCP 计费（新账号 $300 试用金；L4/A100） | ✅ 官方 `gcloud colab executions` 全 CLI | 一次性 setup（10 分钟，2 步浏览器） |
| Kaggle | 免费配额 30h/周（P100/T4×2） | ✅ 官方 CLI | 换个平台（包已备好 kaggle/） |

⚠️ GitHub 上"利用 Colab 算力"的库 = 教程 notebook（仍人点）或浏览器自动化 hack（拿 cookie 模拟点击，脆弱+灰区）——不存在官方消费版 CLI，这是 Google 产品分界。

## 数据流

```
mac ──bundle──▶ ostore(cc) ──gdrive 同步──▶ Google Drive
                                              │
                                    Colab GPU（A100/L4/T4）
                                              │
                              训练 + eval + bundle/merged 写回 Drive
                                              │
mac ◀──ostore gdrive 回同步 / 手动下载──────────┘
```

## 一次性准备（5 分钟）

1. **gdrive 重新授权**（OAuth 已过期）：
   在 cc 上生成 → 浏览器打开 → 授权：
   ```sh
   ssh cc 'T=$(grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2);
     curl -s -X POST -H "Authorization: Bearer $T" -H "content-type: application/json" \
       -d "{}" http://127.0.0.1:8781/api/cluster/gdrive/auth-url'
   # 返回的 auth_url 在浏览器打开，走 Google 授权流程
   ```
2. **训练数据上 Drive**（两条路）：
   - gdrive 同步通了：`personal-lm/sync_model.sh` 之外的 cloud bundle 推到 ostore，
     由 gdrive 连接器镜像到 Drive `clipvault-personal-lm/`
   - 手动：把 `corpus/tokens_weighted.bin`、`corpus/tokenizer.json`、
     `lora/{train,valid}.jsonl` 上传到 Drive `clipvault-personal-lm/` 对应位置

## Notebook 1：personal_gpt_cloud.ipynb（从零 GPT，98M）

本地 MPS 训不动的规模。12 层/d=768/98M 参数，A100 上 bf16 约 30-60 分钟。
- 自动 Drive 挂载；checkpoint 每 500 步落 Drive（**中断重跑自动续**）
- 结束导出 bundle → Drive `exports/v<step>/`
- mac 收尾：拷进 `Keepsake/models/personal-lm/`，cv-lm 热加载
  （config.json 带 layers/d_model/heads，cvlm-core 自动按 config 构建）

## Notebook 2：qwen_lora_cloud.ipynb（Qwen3-1.7B 个人风格）

unsloth + QLoRA（4bit，T4 也行；A100 更快）+ packing 全吞吐。
- 训 2 epochs（16.7M tokens）
- 试写验证个人腔调
- **merge_and_unload** → Drive `merged/qwen3-1.7b-personal`
- mac 收尾：
  ```sh
  .venv/bin/python -m mlx_lm convert --hf-path <merged> --mlx-path <mlx-out> -q
  .venv/bin/python -m mlx_lm server --model <mlx-out> --port 8790
  # cv-lm :8788 的 /compose、/complete（Qwen 模式）直接用上
  ```

## 隐私（修订版）

- 允许：Drive（用户信任）、ostore（私有 S3）、Colab VM 运行时（训练期内存）
- 仍然禁止：git、公共 Hub（HF 等）、任何第三方托管
- merge 后的模型 = 个人数据的有损压缩 → 同语料级隐私
