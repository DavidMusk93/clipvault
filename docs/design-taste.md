# ClipVault · Design Taste（产品视觉真源）

> **长期产品**：跨 Mac Web / Android / 未来端共用同一套视觉身份。  
> 改颜色、标签、来源色前先改本文，再改实现。  
> 与 `AGENTS.md` §2 产品 taste 配套：叙事气质 + 本文件 = 可执行 token。  
> **沉淀规则**：Owner 的审美裁决必须写入 **本文件和/或 nmem**（见 `AGENTS.md` §2.0），逐渐形成个性化设计语言——禁止只改实现、不回写真源。

## 一句话

**暖蜂蜜品牌 + 语义色标签 + 克制玻璃壳** —— 像个人器物，不像工具箱皮肤。

## 品牌底色

| Token | Hex | 用途 |
| --- | --- | --- |
| Honey（品牌主色） | `#C47A2C` | Android primary、text 类型标签、暖光氛围 |
| Cream | `#F8F1E7` | Android 浅色背景 |
| Ink | `#1C1410` / Web `#1D1D1F` | 正文 |
| Apple chrome bg | `#F5F5F7` | Web 系统浅灰底 |
| Accent（系统蓝） | `#0071E3` | Web 链接/焦点/主按钮（系统感，不抢 Honey） |

Web 与 Android 可有平台壳差异，**语义色必须一致**。

## 剪贴板类型标签（Type badge）

列表/卡片左上角类型 chip。Android `typeStyle()` 与 Web `.badge.type-*` **同一 hex**。

| type | 中文 | Hex | 软底 α≈12% |
| --- | --- | --- | --- |
| `text` | 文本 | `#C47A2C` | Honey |
| `note` | 笔记 | `#C47A2C` | Honey（主动写下，与捕获文本同色不同字） |
| `image` | 图片 | `#2E7D32` | 绿 |
| `url` | 链接 | `#1565C0` | 蓝 |
| `html` | HTML | `#6A1B9A` | 紫 |
| `rtf` | 富文本 | `#EF6C00` | 橙 |
| `pdf` | PDF | `#C62828` | 红 |
| `file` | 文件 | `#455A64` | 蓝灰 |
| `other` / 未知 | 其他 | `#5D4037` | 棕 |

规则：

1. 标签用 **语义色字 + 同色 12% 软底**，不要灰底灰字。  
2. 文案用中文（HTML/PDF 可保留拉丁缩写）。  
3. 禁止所有类型共用一个灰色 badge。  
4. 新类型：先补本表，再改 Android / Web。

## 操作日志来源色（Ops source）

Web `.ops-item.src-*` 与 Android `opsSourceStyle()` 共用：

| source | rail / ink 方向 |
| --- | --- |
| `web` | 蓝 `#007AFF` |
| `clipboard` | 绿 `#34C759` |
| `backup` | 紫 `#AF52DE` |
| `maintenance` | 橙 `#FF9500` |
| `app` | 靛 `#5856D6` |
| `sync` | 青 `#32ADE6` |
| `system` / 其它 | 灰 `#8E8E93` |

布局：左侧 3px 色轨 + 来源 pill + 字段区 **不 soft-wrap、可 XY pan**。

## Trae 会话 IM 角色色

时间线按即时通讯俯瞰：用户右、助手左、工具/系统居中偏左。语义色与类型标签同源，禁止灰底灰字一锅炖。

| role | 中文 | 对齐 | Ink / 软底 | 轨 |
| --- | --- | --- | --- | --- |
| `user` | 你 | 右 | Honey `#C47A2C` / 12% | Honey |
| `assistant` | 助手 | 左 | Ink + 白气泡 | Accent `#0071E3` |
| `tool` | 工具 | 左 | `#1565C0` / 12% | `#1565C0` |
| `system` | 系统 | 中 | `#8E8E93` / 12% | 灰 |

映射：`UserPromptSubmit`→user；`Stop`（及 assistant 正文）→assistant；`PreToolUse`/`PostToolUse`→tool。`SessionStart` **不进气泡**（cwd 不是一句对话）。无正文的 `Notification` 也不进。同一 `tool_use_id` 有 Post 则不画 Pre。

**溢出**：气泡 `min-width:0`；等宽覆盖 highlight.js 的 `white-space:pre`，必须 `pre-wrap !important` + `overflow-wrap:anywhere`。聊天正文限高，内部滚动。

## 源码绑定

| 端 | 文件 |
| --- | --- |
| Web | `web/index.html` — `:root` type tokens、`.badge.type-*`、`typeMeta()` |
| 归档 View | `web/assets/archive-view.css` + `archive-reader.js` `enhanceTechnicalMedia` |
| Android | `ui/ContentRender.kt` `typeStyle()`；`MainActivity.kt` `opsSourceStyle()` |
| 产品约定 | `AGENTS.md` §2 + **本文** |

## 数据语义（与视觉配套）

| 层 | 可变？ | 说明 |
| --- | --- | --- |
| Capture payload | **不可变** | 复制瞬间的事实；`content_hash` 锚定 |
| User evaluation | **append-only 历史** | 表 `user_evaluations`：每次提交一行；星级 **0.5–5 半星步进**，可多次改 |
| Latest projection | 可覆盖 | `user_rating` (REAL) / `user_note` 取最新；铅笔入口高亮 |

**UI（apple-design sheet）**：玻璃 sheet；header **紧凑星**（间距紧、左半点半星）；备注 + 提交；历史时间线。主卡片仅 **铅笔** 入口。

## 阅读选区（View 内划线 / 评论）

| Token | 值 | 用途 |
| --- | --- | --- |
| 选区菜单 | macOS 浅玻璃 `rgba(246,246,248,.92)` blur 40 · 高 28 · 圆角 8 · 黄点=划线 | 备忘录/Safari Reader，不是 iOS 黑胶囊+粗三角 |
| 评论卡片 | 与卡片「评价」sheet 同构：18 圆角玻璃、15px 输入、底部 Reddit 轨「记录」 | 不要另做一套胶囊；不要只显示最新一句 |
| 评论 header | **单行 28px flex**：`评论` + 黄条 + 摘录 \| 右侧小按钮 取消/提交。标题/摘录/按钮同一 `13px / line-height:28px` strut；用 `span`，不用 `p`/`strong`/嵌套 grid | 左右必须共一条光学中线；禁止再 translateY 修偏 |
| 高亮 | Apple Notes 黄 `#FFD60A` 叠层 | `mark.cv-hl` / `::selection` |
| 有评论 | 底部 inset 1.5px `#0071E3` | 划线带想法 |
| 动效 | 从选区长出 `scale(.96→1)` + 16–200ms ease-out | 空间来源是文字，不是屏幕中心 |
| 位置 | 优先选区上方，空隙不够再翻到下方；caret 对准中点 | **永不覆盖选中文字** |

## 归档 View 技术介质（代码 / 流程图 / 图表）

Readability 会剥掉出版商 `<style>` 和 Chroma/Shiki class，只留下灰 `pre` + 拆开的 `img`/`figcaption`。View 必须自己给这些介质一张「板」，不要让它们和正文灰底糊在一起。

| Token | 值 | 用途 |
| --- | --- | --- |
| 纸 | `#fff` 正文，不用 Pico 灰洗 | 长文阅读面 |
| 代码表面 | `#1D1D1F`（Ink 反相）+ `#F5F5F7` 字 | 代码是另一种介质，不是浅灰盒子 |
| 代码工具条 | 32px · 11px 语言 · 24px「复制」 | 与评论 header 同一套小控件密度 |
| 语法色 | keyword `#FF7AB2` · string `#FF8170` · comment `#8E8E93` · number `#D0BF69` | Xcode Dark，不另开彩虹主题 |
| 图板 | 14 圆角 · 浅纸 `#F5F5F7` · 题注同色底栏 | **默认**。透明流程图常混着深色标注/虚线箭头，黑井会把它们吃掉 |
| 深图板 | 仅当图本身整体偏暗且不太透明 → `.is-dark` `#1D1D1F` | 暗色截图 / 暗色 UI。禁止「透明 + 浅色节点」就铺黑底 |
| 放大 | 暗 scrim `rgba(15,15,16,.86)` · 点击图/点空白关闭 | 看清流程图；不改 CAS |

规则：只在 View 运行时包 `.cv-code` / `.cv-figure` / `.cv-table`。禁止为了高亮去改 `archive_html`。

## 品味禁区

| Don't | 为什么 |
| --- | --- |
| 每端各调一盘色 | 品牌碎裂 |
| 灰 badge 通吃类型 | 扫一眼分不清介质 |
| 堆彩虹装饰、无语义 | 像玩具不是器物 |
| 为「好看」改交互语义色 | 色 = 信息通道 |
| 就地改 capture 正文当「备注」或当笔记 | 毁掉 hash/同步/审计；Compose 必须是新的 `type=note` 行 |
| 评价内容挂主卡片 / 多阶段芯片 | 触发 masonry 重绘；交互过重 |

## 交互密度（轻量 & lazy）

**原则：展示尽可能充足的信息，同时尽可能轻量 & lazy。**

| Do | Don't |
| --- | --- |
| 单 ref（`copyCount ≤ 1`）只露主时间，无「事件时间线」入口 | 每张卡片都挂可展开时间线壳 |
| 多 ref 才露出时间线；内容 **点击后** 再 fetch | 列表阶段预拉 events |
| 展开只 **就地变高**（列高 remeasure），不 remount 瀑布流 | `rebuildFromData` / 整墙重排 |
| 字段/日志：需要时再滚、再加载 | 为「完整」预渲染隐藏 DOM |

时间线 = **多捕获历史** 的二级细节，不是默认噪音。

瀑布流内 **禁止就地 expand**（列高/重排不稳）。多 ref 时间线用 **底部可交互 toast 卡片** （毛玻璃 sheet + scrim，lazy fetch，Esc/遮罩关闭）—— 列表零布局扰动。

**入口**：不要单独「事件时间线」按钮；用 header 的 **×N 引用徽章** 作为唯一 affordance（单 ref 无徽章、无入口）。


## 紧凑布局 + 锚定 popover

| Do | Don't |
| --- | --- |
| 卡片只露：类型色 badge · 可选 ×N · **一个**时间 | 「首次 / 最近捕获」次要时间行 |
| 时间线 popover **贴着 ×N** 弹出（可上下翻转） | 固定屏幕底大 sheet 脱离上下文 |
| 轻 scrim + 毛玻璃小卡 | 重遮罩抢戏 |
| transform-origin 来自触发点 | 从屏幕中心 scale |

## 片段折叠（已移除）

**已回滚。** substr fold 过于激进，误伤独立剪贴片段。主规则仅 **exact content_hash latest-alive**。历史被 soft-delete 的条目在启动时按 operation_logs(`source=substr_fold`) 自动 restore。

