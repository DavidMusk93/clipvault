# personal-lm 补全质量盲评报告（v2.5）

方法：6 个真实打字前缀（取自训练 watermark 之后的全新笔记，模型从未见过），
收集生产管线输出（检索命中 or Qwen-LoRA 兜底），由评审模型逐条打分。
盲评样本：eval/blind_sample.json（含 prefix + completion + source，可提供给任意外部模型复核）。

评分口径：2 = 明显是"我想写的"；1 = 沾边可用；0 = 无关/乱码。

| # | 场景 | 引擎 | 输出 | 分 |
|---|---|---|---|---|
| 1 | cdn 抖动分析（大盘 URL） | retrieval | '- cdn 监控大盘：https://grafana.byted.org/d/0KNAOkxVzx/tide-woker-status-viewer?' | 2 |
| 2 | doubao 迁移（lark 链接） | qwen | 'x/DMJyNzQxNzY1'（URL 乱码） | 0 |
| 3 | gw-pulse（评估 pg 是否健康） | qwen | '评估pg 是否有垃圾数据？' | 1 |
| 4 | clipvault 语言模型 | retrieval | '- 我现在希望为clipvault 增加两个大功能：…生成个人风格的文字或者技术方案。' | 2 |
| 5 | 部署流水线复盘 | qwen | '：1.部署流程没有复用，'（断路器截断后） | 1 |
| 6 | 写个脚本批量检查 | retrieval | '- 批量检查，不要一台台串行，太慢了！！' | 2 |

结论：
- 检索命中场景 3/3 满分——"意图"本质上是你自己写过的东西，local-first 召回是最强信号。
- Qwen-LoRA 兜底 2 条可用 1 条乱码——初版 LoRA（rank16/16层/3000iter/2.9M tokens）太浅；
  深训（全28层/8000iter/lr2e-4）已启动，预期兜底质量上升。
- 27M 从零模型在盲评中不再参与 ghost 主路径（检索 miss + Qwen 即为兜底链），
  其角色收缩为离线兜底与学习实践产出。
