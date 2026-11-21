# personal-lm 隐私护栏（必须遵守）

本子项目训练的是**个人专属模型**：语料来自 ClipVault 私有剪贴板、nmem 个人记忆、
agent 会话日志。产物全部属于个人隐私数据。

## 铁律

1. **绝不推送产物**：`corpus/`、`checkpoints/`、`exports/`、`models/`、
   `*.safetensors`、`*.ckpt`、`tokenizer.json`、`manifest.json` 等只存在于本机
   （`CLIPVAULT_HOME/models/` 或 `personal-lm/` 本地目录）。
2. **可以推送的只有**：训练/导出/评估**代码**、README、设计文档。
3. 推送前必查（CI/人工皆可）：

```sh
cd ~/dev/ClipView
git ls-files personal-lm | grep -E \
  'corpus/|checkpoints/|exports/|models/|\.safetensors$|\.ckpt$|\.pt$|tokenizer\.json$|manifest\.json$' \
  && echo "!!! 隐私违规：产物被追踪 !!!" || echo "OK: 无隐私产物入库"
```

4. 语料里若混有密码/token（剪贴板常客），训练语料构建时**按行过滤**
   （`data/clean.py` 负责 secret 正则剔除）。
5. bundle 分发：默认只落 `CLIPVAULT_HOME/models/`（本地）。若未来要跨机，
   走私人渠道（osync/ostore 私有前缀），不走公共 GitHub/HF Hub。

## 为什么

- 剪贴板是最高敏感数据面（密码、内网地址、私聊）。
- 模型权重是对个人语料的有损压缩，但可被提取记忆内容 → 视同语料级敏感。
