---
doc_id: clipvault-session-analysis-v2
kind: design
status: active
authority: design
applies_to:
  - trae_hooks/mine.py
  - trae_hooks/server.py
  - trae_hooks/web/sessions.html
depends_on:
  - docs/trae-hooks.md
  - docs/design-taste.md
  - AGENTS.md
supersedes:
  - ad-hoc-analysis-sheet-v1
verified_by:
  - tests/session-mine.test.mjs
  - tests/session_mine_main.py
  - tests/metrics-plane.test.mjs
---

# Session Analysis · 第一性原理与契约

## 1. 结论（结论前置）

会话分析不是「把会话统计成一个仪表盘」，而是**把一次 Agent 劳动换算成可归因的
损耗账本，并把每个结论写成 Agent 自己可以复测的闭环**。

```text
分析的第一性原理
  输入: 事件流(hook_events) + 经济量纲(llm_usage / turn_context)
  输出: 两个消费者各取所需, 同一份计算
        ┌─────────────────────┬──────────────────────────────┐
        │ 人                  │ Agent                        │
        │ agent 干了什么      │ 下一次该改什么 + 怎么验证    │
        │ 时间/钱 花在哪      │ metric id + now + target     │
        └─────────────────────┴──────────────────────────────┘
  判据: 一条结论只有同时可归因 / 可行动 / 可验证 / 有量纲, 才算有价值
```

四层模型（每层只依赖下一层，禁止跳层下结论）：

```text
L0 账本 Ledger       事件次数与时长 (turn / tool / file / phase / cost)   = 事实
L1 归因 Attribution  损耗落到具体 turn / event / 命令 / 文件上, 给出秒与 $  = 事实加权
L2 结论 Finding      每条的 cause chain + action + gate + metric(target)   = 可执行断言
L3 闭环 Loop         metric id 可在下一个窗口重算, 输出 Δ 基线             = 可验证
```

## 2. 为什么 v1 的「建议」没有价值（反模式，必须禁止）

| 反模式 | v1 实例 | 为什么无价值 |
| --- | --- | --- |
| 关键词 → 断言 | 「重申约束 ×22，占 19%」 | 正则命中 `必须/注意` 不等于用户被违反；无可归因事件 |
| 独立阈值 → 建议 | 「49/69 prompt 缺路径」 | 散文 prompt 天生无路径；该数不预示任何损耗 |
| 跨会话聚合当成会话结论 | 「冗余读 3734」 | 窗口被 12000 行截断，主语是「7 天全球」却写成「本会话」 |
| 复述数据当结论 | 「成本曲线：首日 $0.26 / 最新 $0.62」 | 读数不是结论；没说该改什么 |
| 无可验证目标 | 「MCP 面过窄或过散」 | 无法复测、无法判定已修复 |
| 受众错位 | 给用户的「把仓库根写进任务」 | 用户已知；Agent 侧无动作 |
| 证据不是证据 | `evidence=read_top=[('/Users/...', 5)]` | Python counter repr，不是触发该条的原因与代价 |

判据一句话：**如果删掉结论句，只留下证据，读者无法自己算出「亏了多少」，这条就该删。**

## 3. 损耗账本（L1 的唯一口径）

只有 5 种损耗被承认；每种都必须能落到 `turn / event_id`，并给出 seconds 或 USD。
**秒数互斥**：一次调用只归一类，优先级 `fail > retry > reread > locate`，
因此账本秒数可以直接相加，不会重复计算（否则「工作 452s / 损耗 1182s」这类
越界数字会直接毁掉可信度）：

```text
L1a 失败重试   exit_code != 0 的调用墙钟 + 同族重试墙钟 + 该回合按失败工具占比分摊的 $
L1b 重复读     同一文件在同一窗口第 2 次起的读取墙钟 (读到第 N 次说明上下文在重建)
L1c 空等轮询   is_wait_tool (CheckCommandStatus 类) 墙钟: 没有产出的等待
L1d 前缀重填   cacheWrite>0 的回合: 前缀被改写, 下一回合整段重新预填 ($ 按本窗混合单价估算)
L1e 返工往返   短催/纠正/催促产生的回合本身成本 (秒 + $): 本可避免的一次完整回合
L1f 定位搜索   缺路径/仓库线索回合里的 search 族 (rg/find) 墙钟
L1g 长空档     相邻事件间隔 >600s（>10 分钟无任何事件, 模型生成不算）累计
```

「定位搜索」只算 **search 族**（`rg`/`find`）落在缺路径线索回合上的墙钟；
同一文件第 2 次起的读取算**重复读**，优先于定位。

另有两条**上下文成本**（估算，必须标注）：skill 正文 tokens × 剩余回合数、每回合
history 增长。它们不单独成条，挂在命中的 finding 上。

口径强制：

- `s` 与 `usd` 分开给，`kind` 标 `measured` / `estimated`，禁止混算成单一分数；
- 排序按 `usd` 优先、`s` 次之（无 usage 平面时按 `s`）；
- 聚合窗口必须写进输出：`scope=session` 只算该 session；`scope=recent` 是 7 天且
  必须报告被 12000 行截断这件事。

## 4. 输出契约

### 4.1 人类面（sheet 默认）

```json
{
  "ok": true,
  "scope": "session",
  "window": {"from": "...", "to": "...", "turns": 1, "tools": 18, "truncated": false},
  "summary": {"health": {"score": 78, "grade": "有损耗"}, "...": "KPI 与旧字段兼容"},
  "metrics": [{"id": "reread_ratio", "label": "重复读/文件", "value": 4.0,
               "baseline": 1.2, "target": 2.0, "unit": "次", "dir": "down"}],
  "losses": [{"id": "reread", "label": "重复读", "s": 62.0, "usd": 0.03,
              "kind": "measured", "share": 55.0}],
  "findings": [{
     "id": "reread", "sev": "high", "axis": "agent",
     "title": "热文件反复读", "claim": "...", "cause": "...",
     "action": "Agent 侧动作", "gate": "AGENTS.md 长期约束",
     "impact": {"s": 62.0, "usd": 0.03, "kind": "measured"},
     "metric": {"id": "reread_ratio", "now": 4.0, "target": 2.0, "unit": "次"},
     "refs": [{"turn": 1, "ts": "...", "event_id": "...", "label": "read mine.py"}],
     "confidence": 0.9
  }],
  "blocks": {"...": "L0 账本, 与 v1 兼容, UI 始终展开"}
}
```

### 4.2 Agent 面（`GET /api/mine?format=agent&baseline=1`）

Agent 面是**契约**，字段稳定、可解析、带复测指令。额外返回：

```json
{"view": "agent",
 "brief": "# 会话分析（可直接读的 Markdown, ≤ 3KB）\n...",
 "verify": {"metric_ids": ["reread_ratio", "fail_n"],
            "rerun": "python3 trae_hooks/mine.py --agent --scope session --session-id <id>",
            "expect": "同一窗口重跑, metric.value 向 target 移动"}}
```

规则：

- `brief` 只含「结论 → 影响 → 动作 → 复测」四段，禁止贴表格与 tool 正文；
- `metric.id` 是跨会话稳定的字符串，Agent 用它在下一窗口做 Δ，禁止用中文 label 做 key；
- 任何 `sev=high` 的 finding 必须同时有 `action` 与 `metric`，否则降级为 `note`。

### 4.3 基线（Δ）

`baseline=1` 时对**同长度前窗**重算一次：`scope=session` 取上一个会话；
`scope=recent` 取前 7 天。基线缺失时 `baseline: null`，UI 不画 Δ，不猜。

## 5. UI 契约（sheet）

```text
+------------------------------------------------------------------+
| 会话分析        [当前会话][最近 7 天]        [复制 AGENTS 草稿][x] |
| 时间窗 · 回合 · 工具 · 实例 · (截断警告)                          |
| 方向 chips: 工作目录 Git Taste 任务描述 用户提醒 操作流程 ...      |
+------------------------------------------------------------------+
| ① 损耗判定   score + 4 KPI($ / 墙钟 / 缓存命中 / 失败)             |
|    时间构成条 (工作蓝 / 等待灰 / 失败红)  钱构成条 (出/缓写/缓读)  |
+------------------------------------------------------------------+
| ② 损耗排行   按 $/秒 排序, 每条: 影响数字 + 指标 now→target        |
|    证据 chips(回合/事件, 可点) · 原因 · 动作 · 闸门                 |
+------------------------------------------------------------------+
| ③ 回合时间轴  每回合一块, 阶段色, 宽=工作秒; 点击就地展开该回合明细 |
+------------------------------------------------------------------+
| ④ 账本       工具 / 文件(读·写) / 阶段 / 成本 / 上下文 / 提醒       |
|    始终展开, 顶部锚点导航 (不使用 <details> 折叠)                  |
+------------------------------------------------------------------+
```

强制规则：

1. **不折叠细节**：方向与账本区一律可见；`<details>` 只允许用于单个证据的超长原文。
2. **色彩是信息通道**：损耗用暖红→蜂蜜→灰；时间=Accent 蓝；钱/缓存=青
   `#2F8F83`；用户轴=Honey；Agent 轴=Accent；良好=绿 `#2E7D32`。阶段色与设计
   真源一致。禁止彩虹装饰，禁止灰底灰字一锅炖。
3. **交互**：KPI/指标可点到对应账本区；证据 chip 点到时间轴并高亮该回合；
   时间轴回合可点开就地明细（不是 overlay）。所有色块带数值，色不单独承载信息。
4. 铺满 sheet 用不透明底，**禁止 `backdrop-filter`**（每次 hook 背后重算 = 整页重绘）。
5. 自动刷新保留滚动位与已展开的回合明细；内容 signature 不变不重绘；正在读
   （回合明细打开）时只标 `is-pending`，不重绘。
6. 禁止 `setInterval` 刷 DOM（沿用 SSE `hook_event` 去抖）。
7. `?mine=1` 是分析深链（浏览器验收、直接打当前会话分析用）；不改变默认不打开的行为。

## 6. Worked example（不可与实现同源的最小 oracle）

窗口 A（构造）：2 回合；回合 1 有 4 次 `rg` + 1 次 `read a.py` + 1 次
`read a.py` + 1 次失败 `cargo test`；回合 2 用户只说「继续」。

期望输出（口径可复算）：

```text
reread:      1 次重复读 × 平均读耗时 = s>0, usd=0     kind=measured
fail_retry:  1 次失败 + 0 重试, $ = 回合1 成本 × 1/7   kind=measured
rework:      回合 2 成本全量计入返工                    kind=measured
metrics:     reread_ratio = 1.0, fail_n = 1, extra_trips = 1
```

反例（必须不出现）：`重申约束` 关键词建议、`prompt 缺路径` 计数建议、
跨窗口聚合写成「本会话」。

## 7. 边界

- 上下文 tokens 是估算（chars / 校准 cpt），带 `est_ratio`，禁止当账单据。
- Trae 侧无 usage/cost（hook stdin 实测无字段），Trae 会话只有 `s` 维度。
- `scope=recent` 受 12000 行上限约束，`truncated=true` 必须显式暴露。
- 未做：跨实例（多机）归属拆分；记忆 ROI（memory id ↔ 结果）只有计数，
  尚未与失败率/成本联算。
