# ClipVault · Design Taste（产品视觉真源）

> **长期产品**：跨 Mac Web / Android / 未来端共用同一套视觉身份。  
> 改颜色、标签、来源色前先改本文，再改实现。  
> 与 `AGENTS.md` · 身份 配套：叙事气质 + 本文件 = 可执行 token。  
> **沉淀规则**：Owner 的审美裁决必须写入 **本文件和/或 nmem**（见 `AGENTS.md` · 身份），逐渐形成个性化设计语言——禁止只改实现、不回写真源。

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

入口与笔记统一：ClipVault `:8080` 顶栏「会话」弹出霜层 + 圆角纸面（`#sessionsPanel`），不要另开 `:9488` 标签。`:9488` 是 DuckDB 进程口，只给本机反代。

时间线按即时通讯俯瞰：用户右、助手左、工具/系统居中偏左。语义色与类型标签同源，禁止灰底灰字一锅炖。

| role | 中文 | 对齐 | Ink / 软底 | 轨 |
| --- | --- | --- | --- | --- |
| `user` | 你 | 右 | Honey `#C47A2C` / 12% | Honey |
| `assistant` | 助手 | 左 | Ink + 白气泡 | Accent `#0071E3` |
| `tool` | 工具 | 左 | `#1565C0` / 12% | `#1565C0` |
| `ask` | 需要你 | 左 | Honey 软底 + 边 | Honey |
| `system` | 系统 | 中 | `#8E8E93` / 12% | 灰 |

映射：`UserPromptSubmit`→user；`AskUserQuestion` 的 **Post 答案**→user（这也是用户输入）；`Stop`→assistant；`PreToolUse`/`PostToolUse`→tool。`Notification` 的 `permission_prompt` / `ask_user_question`，以及 `AskUserQuestion` 的 Pre→**ask「需要你」**。`idle_prompt` 是完成不是等待。`SessionStart` **不进气泡**。无正文的 `Notification` 不进。同一 `tool_use_id` 有 Post 则不画 Pre，**AskUserQuestion 除外**（要同时留下问题和答案）。

**两层滚动**：会话列 `#sessionList` 与消息 `#thread` 是两个 scroller。`html, body { height:100%; overflow:hidden }`，`overscroll-behavior: contain`。禁止 `main { min-height: 100vh }` 让整页带着列表一起滚。

**跟底**：靠近底部时新消息钉住 `#thread` 底部（不动画）。用户上翻则停止跟踪，露出「↓」；有未读时 Accent 底。禁止新进展把人拽回底部。进入页默认打开**最新会话**。

**展开 vs 压缩**：用户输入有限，**每一条用户气泡都展开**（含 AskUserQuestion 的选项答案）。助手结论（`Stop`）同样展开。工具 slog 只在 **助手一侧** 收成 `history-bundle`（左对齐），**每一段操作的最后一条始终展开**。bundle 展开后每条是可点开的 `history-item`，里面是完整工具气泡；「查看全部」一次打开。**展开目录项**：默认手风琴（一组里只开一条），正文**就地**出现在该行下面，限高内部滚动。禁止 `position:absolute` overlay 盖住后面的用户/助手气泡。禁止目录行点不开正文。禁止把用户话术卷进「更早 N 轮」。库 `ts` 是 naive UTC；**每条消息时间戳用本地 `YYYY-MM-DD HH:mm:ss`**，禁止只用「今天」或相对时间当消息时刻。

**需要你**：Trae 自己几乎不提示。`permission_prompt` / `ask_user_question` 走 SSE `needs_user` 推到 ClipVault 墙（蜂蜜条 + 会话钮圆点），hook 同时 `osascript` 系统通知。确认动作仍在 Trae 里完成。

**实时**：Trae 页走 nmem SSE 契约（`GET /api/stream`：`retry: 3000`、15s ping、满 32 发 `resync_required`、浏览器原生重连）。禁止 `setInterval` 整页重绘。加载是显式状态机，不是一堆 timer。打开面板 **先画上次快照**（`localStorage` `cv.trae.snap.v1` stale-while-revalidate），再 SSE 确认；禁止把缓存当真源，禁止写入 tool 正文。首屏只画用户/助手/Ask（`view=beats`）；工具目录关闭时不砌子行。`trae_sessions_ttfp` / `trae_sessions_net` / `trae_sessions_paint` 立即上报。**线程按 `event_id` keyed 调和**（同笔记预览：禁止每次 SSE `innerHTML` 整页换上）。新事件 `GET /api/event?id=` 追加再 patch。`/api/events` 列表不含 tool_input/tool_response（Ask 除外）；`view=tools` 必须是全量 stub，禁止 LIMIT 200 砍尾。每次 hook 禁止重拉 `/api/sessions` + 全量 events（列表 1s 合并）。工具 hook 用 SSE stub，禁止每条再拉 `/api/event`。会话面板关闭 pause iframe。笔记列表失败禁止开空白新笔记。bundle 项 **延迟加载正文**；点开一条不得重绘其它条。目录项就地展开，禁止 overlay 盖住对话。抖动用本机 `ui-metrics` 的 `trae_sessions_ttfp` / `trae_sessions_net` / `trae_sessions_cls` / `trae_sessions_paint` / `trae_sessions_load` / `trae_sessions_fsm` / `trae_sessions_error` / `trae_sessions_longtask` 追溯。

**聊天 chrome**：左栏 `#F2F2F7` 会话行（标题=最近 prompt，不是整段 uuid）；列卡还要最后一条本地 `YYYY-MM-DD HH:mm:ss`、实例 `instance_id`、agent 来源 `source`、工作目录 `cwd`。右栏 IM 气泡。工具默认折叠。用户/助手气泡不套第二层 max-height 滚动。会话「分析」= 损耗账本 sheet，结构固定为 **① 损耗判定**（score + 分量 KPI + 时间/钱构成条 + 缓存环形）→ **② 损耗排行**（按 $ 与按秒两张横向柱 + 每卡：影响数字 / 指标 now→target / 证据 chips / 原因·动作·闸门 / ack）→ **③ 回合时间轴**（阶段色，柱=墙钟，红点=有失败，点回合就地展开）→ **④ 账本**（工具/文件/阶段/成本，**始终展开**）。owner 规则：**不允许折叠细节**，`<details>` 不得隐藏方向与账本。色彩是信息通道且必须带数字：时间=Accent 蓝 `#0071E3`、钱/缓存=青 `#2F8F83`、损耗=暖红 `#C2410C`、注意=Honey、用户轴=Honey、Agent 轴=Accent、良好=绿 `#2E7D32`；阶段色 `review #6E56CF` / `debug #C62828` / `ship #2E7D32` / `taste #1565C0`。禁止灰底灰字一锅炖，禁止彩虹装饰，禁止用色块代替数字。分析 sheet 铺满线程时用**不透明底**（禁止 `backdrop-filter`，否则每次 hook 都在背后重算 = 整页重绘），自动刷新保留滚动与已展开的回合明细。

**图表选型（视觉真源补充）**：比例分段条必须**段间留 3px 空隙 + 每段 0.5px 内描边**（相邻比例不得融成一团）；一张图只允许一种单位（秒与 $ 不混轴）；环形用于 part-to-whole 与单值比率（中心出数），折线只用于 ≥3 点趋势，柱用于有序多点，横向柱用于排序比较，>6 片不用饼图；每个色块都必须可读出数值。实现 `web/mine-charts.mjs`，后端在 `_table(..., chart={kind,label,value,unit})` 处声明。

**形状随数据，不随后端声明**：后端的 `kind` 是建议，前端 `pickKind()` 可推翻——
- **柱状不适合就别硬画**：parts ≤ 4 或单值占比 ≥ 70% 时，柱只剩几根细条 + 大片空白，改**环形**（part-to-whole，中心出数，图例带值+%）。
- **折线 ≥3 点**，2 点降级为柱。
- **数据条一律直角**（`border-radius: 0`）：圆角端会压住右侧数值标签/相邻文字，也让短条变成圆点。环形/轨迹线不受此限。
- 图例放 **HTML**（不用 ECharts legend）：长标签会换行、撑高块，不会叠到环/条上。

**闭环色**：ack chip — 已闭环=绿 `#2E7D32`、未改善=暖红 `#C2410C`、无目标/已忽略=中性灰；按钮中性边框 + Agent 轴蓝 hover。禁止用色块代替“闭环/未改善”文案。

**会话列属性色**：每张卡用柔和语义色表达三个独立属性，禁止彩虹装饰。色 = 信息通道。

| 属性 | 通道 | 档位 |
| --- | --- | --- |
| 更新时间 | 暖度（Honey 家族 → 雾） | `fresh` &lt;1h 蜂蜜 `#C47A2C`；`today` &lt;24h 浅蜜 `#C9955A`；`week` &lt;7d 鼠尾绿 `#5B8A72`；`old` 雾灰 `#8E8E93`。卡底 `color-mix` 约 11%，时间 chip 同色 16% 软底 |
| 消息量级 | 工具蓝浓度 | 左 3px 轨 + 「N 条」chip。`xs` &lt;20 / `s` ≥20 / `m` ≥80 / `l` ≥200，α 约 16%→64% |
| agent 来源 | 中性 pill + 6px 来源色点 | `source`：`trae` 雾灰 `#8E8E93`、`pi` 紫 `#6E56CF`、`grok` 墨 `#3A3A3C`、`codex` 青 `#2F8F83`；未知来源中性灰。标签用 `sourceLabel` 首字母大写；卡与 head 同步 |
| 置顶 | Accent 图钉 + 蜂蜜实底 | 钉在列顶。本机 DuckDB `session_pins`。**不进**墙 pin rail，不走 `POST /api/clips/pin` |

禁止灰底灰字一锅炖；禁止用位移/scale 表达量级。跟最新会话仍按 `last_ts` 最大，不按置顶后的第一张。

**溢出**：气泡 `min-width:0`；等宽覆盖 highlight.js 的 `white-space:pre`，必须 `pre-wrap !important` + `overflow-wrap:anywhere`。工具输出才限高。

## 源码绑定

| 端 | 文件 |
| --- | --- |
| Web | `web/index.html` — `:root` type tokens、`.badge.type-*`、`typeMeta()` |
| 归档 View | `web/assets/archive-view.css` + `archive-reader.js` `enhanceTechnicalMedia` |
| Android | `ui/ContentRender.kt` `typeStyle()`；`MainActivity.kt` `opsSourceStyle()` |
| 产品约定 | `AGENTS.md` · 身份 + **本文** |

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
| 正文字体 | 系统黑体：SF Pro / PingFang SC | 中文技术文不能用等宽体当正文 |
| 代码字体 | **JetBrains Mono**（OFL-1.1，自托管 `web/assets/fonts/`） | `pre` / `code` / `.cv-code`。禁止 Google Fonts / jsDelivr；`font-src 'self'` |
| 代码表面 | `#1D1D1F`（Ink 反相）+ `#F5F5F7` 字 | 代码是另一种介质，不是浅灰盒子 |
| 代码工具条 | 32px · 11px 语言 · 24px「复制」 | 与评论 header 同一套小控件密度 |
| 语法色 | keyword `#FF7AB2` · string `#FF8170` · comment `#8E8E93` · number `#D0BF69` | Xcode Dark，不另开彩虹主题 |
| 图板 | 14 圆角 · 浅纸 `#F5F5F7` · 题注同色底栏 | **默认**。透明流程图常混着深色标注/虚线箭头，黑井会把它们吃掉 |
| 深图板 | 仅当图本身整体偏暗且不太透明 → `.is-dark` `#1D1D1F` | 暗色截图 / 暗色 UI。禁止「透明 + 浅色节点」就铺黑底 |
| 放大 | 暗 scrim `rgba(15,15,16,.86)` · 点击图/点空白关闭 | 看清流程图；不改 CAS |
| 标注框 | 16 圆角 · 1.5px Accent 描边 · 20px 「i」圈 · 首段加粗当标题 | Readability 把 aside/callout 收成嵌套 `<article>`；View 再画回来。禁止当正文 h2 进 TOC |

规则：只在 View 运行时包 `.cv-code` / `.cv-figure` / `.cv-table`。禁止为了高亮去改 `archive_html`。

## 分享控件

卡片工具条与笔记栏：**一颗按钮、同一槽**。未分享 `ios_share`「分享」；已分享 `link_off`「取消分享」（可 `.is-shared` Accent）。禁止并排「分享 + 取消分享」。

X Article（`x.com/i/article` / 长帖 dump）：正文插图是 Draft.js atomic `MEDIA`，entity 只有 `mediaId`，真 URL 在 `article.media_entities[].media_info.original_img_url`。重建必须按 id 拼 `<figure><img>`。禁止只认 entity `src`/`url`（会只剩封面、正文图全丢）。`DIVIDER` 画 `<hr>`。正文 URL / LINK / `@` 画 `<a href>`（仅 http(s)，新标签），用已有 `.cv-article a[href]` Accent 下划线。有标题时 `header-*` 下移一级。其余解析不到的 atomic 必须留下 `.cv-x-dropped`，禁止省略。`entityMap` 按 `key` 查。手册：`docs/archive-render.md`。

## 归档续读（墙卡）

归档 View 的 `scroll_checkpoint` 落进 `reader_state`；墙卡**复用「查看」那一颗槽**，读到 3%–96% 时标签变「继续 N%」+ `play_circle`，其余仍是「查看」。禁止再加第二颗「继续阅读」按钮（同一槽规则，同 分享 / 取消分享）。关闭 View 后约 400ms 就地刷新该卡，让标签跟上新位置。阈值真源：`DatabaseManager.readerProgressMap` + 前端 `itemReadProgress`（两端都夹 3–96；回收箱不出）。

打开 View 时，sheet 用 **clip-path** 从被点卡片矩形长到全纸（视觉词典下篇 #76），空间来源 = 卡片，不是屏幕中心。**禁止 transform 卡片**——WebKit 会把里面的 iframe 变空白（同 `.sessions-shell` 的处理）。`prefers-reduced-motion` 或程序化打开（无卡片矩形）退回普通淡入。

## 页面 / 详情转场（View Transitions）

| 场景 | 手段 | 禁止 |
| --- | --- | --- |
| 墙缩略图 → 灯箱大图 | 同 document View Transition：缩略图与灯箱 `img` 共用 `view-transition-name: cv-lightbox-cover`，320ms | 从屏幕中心 `scale`；旧 `materialize` 只作降级 |
| 墙卡 → 归档 View | clip-path 揭示（iframe 不能参与 VT） | 给归档 iframe 设 `view-transition-name` |
| 墙卡 → 笔记纸面 / 会话 | 复用 notes/sessions 的 clip-path sheet 引擎 | 再造一套 |

规则：`startViewTransition` 必须 feature-detect + `prefers-reduced-motion` 跳过 + `finished.catch().finally()` 清 name（重复 name 会锁死下一次过渡）。等真像素：`img.decode()` vs 800ms 赛跑，别让过渡挂在没加载的图上。

## Compose 纸面（笔记编辑器）

独立 `#notesPanel`。列表在左，纸面在右。Markdown **源码和预览分开**，不要 WYSIWYG 揉在同一块 DOM。

| Token | 值 | 用途 |
| --- | --- | --- |
| 霜 | `rgba(245,245,247,.42)` blur 28 | 只糊墙一次。打开时必须挡住墙：chips / format-toolbar / masonry 不可点、不可滚 |
| 列表 | Apple 侧栏 `#F2F2F7` | 和纸面分开；选中 `rgba(0,0,0,.06)` 不是蜂蜜底 |
| 纸 | `#fff` 实心 | 阅读/预览面。禁止再叠 blur |
| 源码栏 | `#FBFBFD` | 比预览略灰，像 macOS 分栏 |
| 标题 | 28px / 700 / -0.03em / 高 52 | 高度锁死 |
| 工具条 | min 36px · 可换行 · 28px 钮 · `#F6F6F8` | **预览不展示标记钮**（`visibility:hidden`）。源码/分栏才露出。删除线是字母 **S** 加删除线，与 H1 一样是字不是图标。禁止预览露工具条；禁止钮面汉字；禁止 `overflow:hidden` 裁标记 |
| 源码 | JetBrains Mono 14.5 / 1.62 · Xcode Light token | `web/assets/fonts/`，禁止 CDN |
| 预览正文 | SF / PingFang 17 / 1.65 · **预览模式宽 = 父容器 61.8%**（黄金分割） | 禁止再卡 `38rem`。窄屏 100%。分栏仍 `max-width: 38rem` |
| 预览代码 | 浅板 `#F5F5F7` + 语言条 + 头栏右簇「换行」「复制」白底浅阴影钮 + Xcode Light | **不是** View 的炭黑井。**默认不换行**（`pre` + 横向滚）。换行是选项。**换行按 token 断**：一个空白串的**非 CJK 段**带内部断点即为一个原子单位（`web/assets/notes-wrap.mjs` → `.notes-tok`），`--ip` 整块下移，不拆成 `--` / `ip`；超长段才在行内兜底断（`display:inline-block; max-width:100%`）。同一模块也盖预览正文/行内代码、源码分栏（`.cm-atomic`）、墙卡片 `.md-preview`；墙的 `pre` / `.is-mono` 是 pan 面不套 guard。禁止 `overflow-wrap:anywhere` / `word-break:break-word`（会 eager 拆 token，且 `keep-all` 挡不住拉丁连字符）。两钮 `gap: 4px`，禁止透明字当按钮、禁止拉开间距 |
| token 断点 | 守：一个空白串的**非 CJK 段**里有 `-` `?` `–` `—` `…` 才套 guard（Chrome 实测：只这些能在串内断） | 不守：ASCII `/` `:` `.` `,` `_` `=` 本就不会断；`，。、：` 等全角/CJK 按字断是中文正常排印，**必须留在 guard 外**（否则窄栏下 guard 被夹紧、兜底断落在 `-` 上）。真源见 `web/assets/notes-wrap.mjs` 注释里的实测矩阵 |
| 模式 | 源码 / 分栏 / 预览；**打开默认预览，新建默认分栏** | 打开已有笔记默认预览；新建进入分栏（源码左 / 预览右），用户可再手动切。CSS 无 `data-mode` 时仍是源码单栏 |
| 分栏滚动 | 块锚点 + 块内进度（VS Code / MarkEdit）。头/底 2px 钉住 max | 禁止全程 `scrollTop/max`。禁止只把视口第一行钉在预览顶。围栏用 `data-source-end-line` 摊到 PRE 内容盒。**预览终局**：lexer 块 hash LRU 编译 + React 18 keyed `.notes-md-block`（`display:contents`，行号在 wrapper）。禁止整页 `innerHTML` 换预览。输入不 `force` remap。图 load 不 remap |
| 保存态 | 11px 文案：未保存 / 保存中 / 已保存 / 保存失败将重试；**仅 state 变化时**做一次交叉淡化 + 槽宽数值 tween（同态只换字，error 倒计时不闪） | 禁止只留圆点；相邻按钮不得跳动（宽度 tween，不是布局动画）；11px 不加 blur；`prefers-reduced-motion` 去掉宽度 tween；失败指数退避 + `online` 重放 |
| Tag | 标题内金色 `#F5A400` 同字号，不是黄胶囊 | `#auto gateway…`；`# 标题`（井号后空格）不算 tag，**标题行里的 `#tag` 要能筛**；点标题 tag / 侧栏 tag / 搜 `#tag` 同一条 `extractNoteTags`；筛选时侧栏一颗可关的滤镜钮 |
| 嵌套列表 | Tab 后源码 `a. b. c.`，再一层 `i. ii.`；预览同样 | 每层 4 空格；预览把 `a.`/`i.` 映成 GFM `1.` 再渲染。禁止 `5.1` |
| 分割线 checkpoint | 源码行写成恰好 `---` 时，下一行自动写入本地 `YYYY-MM-DD HH:mm` | 让多次改动有时间戳。禁止写进围栏代码；已有戳不再盖。`---` 必须单独成行才是 hr |
| 行内计算 | `1+2=` 后幽灵预览结果；**Tab 写入**，其它键丢掉预览 | 不 `eval()`。Tab 有幽灵时优先于列表缩进。`price=` / `==` / 代码围栏不触发 |
| 新一篇 | 32×32 细线 +，无黑底「新一篇」文案 | 新建必须清空预览，禁止留上一篇 HTML |
| 打开/关闭 | Motion 数字弹簧插值窗口：`clip-path: inset(t r b l round r)` 从按钮矩形长到全纸；内容原尺寸被揭开，不 `scale`。结束必须 `clearSheetInline`（清 clip/filter/overflow） | 禁止让 Motion 直接 tween `clipPath` 字符串（`round` 对不上就跳变，会话会卡在按钮洞里）。禁止整页均匀 scale |
| 闲置同步 | 打开面板总是拉列表；`visibility`/`onopen`/`update` 走 `mergeNotesHead`；远端更新补当前篇 | 只靠整页刷新。`mergeHead` 排除 note 不等于笔记已对齐。正在输入时不覆盖 |
| 并发同一篇 | git 快照三路合并。重叠段在**源码**里留 `<<<<<<<` 标记 + 蜂蜜提示条 | 后到的整篇覆盖。不上实时 CRDT。不要把冲突藏进预览 DOM |

规则：工具条向源码插入 Markdown，不改预览 DOM。预览只读。自动保存不得回写编辑器、不得 `mergeHead` 墙。霜层默认 `pointer-events: none`（关掉才能点墙），`.notes-panel.open` 才 `auto`；`main`/`chips`/`top-bar` 同时 `inert`。禁止霜层一直 `none` 把拖动手势漏到控制条。

## 布局与节奏（golden ratio + 增量）

**一句话**：用满宽度、按 **1.618 : 1** 分配主次、只在变化处重绘。

| Do | Don't |
| --- | --- |
| 主次两栏按 **61.8 / 38.2** 分配；分析判定卡 `grid-template-columns: <score> 1.618fr 1fr`（左：判定+构成，右：缓存环形） | 每块独占一整行，右侧留一大片空 |
| 内容自适应父容器宽度；表格 / 图表铺满可用宽度 | 固定窄栏 + 两侧空白 |
| 内边距克制：面板 12–16px、卡片 12–14px、段间距 ≤14px、行高紧凑 | 大 padding / 大 margin / 空行堆叠 |
| 同一套栅格：同一 `gap`、同一圆角阶、同一字号阶 | 相邻卡片字号 / 圆角 / 间距各不相同 |
| 数据变了才重绘**那一块**（section 级 `innerHTML` 对比）；SSE 事件**增量 patch** 卡片计数 / 时间 / 预览 | 整页 `innerHTML` 重画、定时全量刷新、图表全量 re-init |
| 刷新合并到 **≥10s** 或事件驱动；打开面板先画快照 | 1s 级 `invalidate`、每条 hook 重拉列表 |
| 图表用 ECharts，spec 不变就不重挂（按 section 作用域） | 每次刷新把 20+ 个 canvas 全部重建 |

黄金分割真源：`1.618`。会话面板与分析 sheet 的判定卡、笔记预览（父容器 61.8%）、归档 View 的正文/图板都走同一比例。

### Apple HIG 基线（Web 端）

拥挤是失败态。Apple 的解法是**分组 + 呼吸 + 类型层级**，不是把信息塞满：

| 维度 | 规则 |
| --- | --- |
| 间距 | 8pt 栅格：`4 / 8 / 12 / 16 / 20 / 24 / 32`。section 间 **24**，卡片内 **16**，行内 **8–12** |
| 字号（SF） | 标题 17 · 卡标题 15 · 正文 13 · 次要 12.5 · 说明 11.5；`line-height 1.4–1.5`。禁止把正文降到 11px 以下换密度 |
| 层级 | 标题（ink / semibold）→ 数值（semibold + 语义色）→ 标签（role-system）→ 说明（role-system）。一层一个字号，不靠颜色堆叠 |
| 分组 | 系统 grouped 底 `#F5F5F7` + 白卡（`rounded-[14–16px]`、`border-black/6`、无重阴影）；卡间 **12** |
| 控件 | 高度 ≥28（pill 28–32）；圆角：sheet 18、卡片 14–16、控件 pill 或 8–10 |
| 克制 chrome | 筛选器不进 header 墙：scope 用 **segmented control**，方向用**「方向 N/M」disclosure** 收起；默认干净，展开才出现 |
| 图表 | 坐标/数值标签 ≥12px，bar 宽 ≥12，`grid` 给右侧数值留 84px |

反例（已踩）：15 个 chip 平铺成两行、KPI/正文 10–11px、卡片 padding 10px、section 间距 12px——信息没少但可读性崩了。

## 品味禁区

| Don't | 为什么 |
| --- | --- |
| 每端各调一盘色 | 品牌碎裂 |
| 灰 badge 通吃类型 | 扫一眼分不清介质 |
| 堆彩虹装饰、无语义 | 像玩具不是器物 |
| 为「好看」改交互语义色 | 色 = 信息通道 |
| 就地改 capture 正文当「备注」或当笔记 | 毁掉 hash/同步/审计；Compose 必须是新的 `type=note` 行 |
| 评价内容挂主卡片 / 多阶段芯片 | 触发 masonry 重绘；交互过重 |
| 主卡 body 挂关联列表 / 图可视化 | 密度与抖动；关联入口 = 同槽 icon-btn，popover 同 ×N |

## 交互密度（轻量 & lazy）

**原则：展示尽可能充足的信息，同时尽可能轻量 & lazy。**

| Do | Don't |
| --- | --- |
| 单 ref（`copyCount ≤ 1`）只露主时间，无「事件时间线」入口 | 每张卡片都挂可展开时间线壳 |
| 多 ref 才露出时间线；内容 **点击后** 再 fetch | 列表阶段预拉 events |
| 展开只 **就地变高**（列高 remeasure），不 remount 瀑布流 | `rebuildFromData` / 整墙重排 |
| 字段/日志：需要时再滚、再加载 | 为「完整」预渲染隐藏 DOM |

时间线 = **多捕获历史** 的二级细节，不是默认噪音。

瀑布流内 **禁止就地 expand**（列高/重排不稳）。多 ref 时间线用 **底部可交互 toast 卡片** （毛玻璃 sheet + scrim，lazy fetch，Esc/遮罩关闭）—— 列表零布局扰动。会话 bundle 的 `history-item` **就地**展开（手风琴），禁止 overlay 盖住后面的对话。

**入口**：不要单独「事件时间线」按钮；用 header 的 **×N 引用徽章** 作为唯一 affordance（单 ref 无徽章、无入口）。

**关联入口**：墙上 `action-pair` 里与评价同槽的 32×32 `icon-btn`（`data-link`）；笔记栏同槽 28×26 链钮 `#notesLink`（与分享并列）。`linkCount>0` 时 `has-ctx`。详情在锚定毛玻璃 popover `#linkToast`（克隆 ×N），lazy GET。笔记有边时纸面工具条下 **一行 24px pill chip**（语义色点 + 预览，不是第二套列表）；点 chip 跳转，溢出「还有 N」开同一 popover。禁止墙卡 header 第二条 chip、禁止卡片 body 挂关联列表。跳转禁止 `fetchPage({reset:true})`。从笔记跳墙卡必须先关霜层。

**落地信标（跳转 / 从 picker 选中）**：墙卡 `.is-flash` = Accent `#0071E3` 描边（`outline` 2px / offset 2px，不改 `border-width`）+ `scale(1.02)` + 抬高 `z-index`，卡片进视口后再亮、持约 850ms 后 transition 收回。两张卡很近时也要一眼能分清落点。禁止 `translateY` / 持久选中态 / 改 border 宽度（会撑 masonry）。`prefers-reduced-motion` 只留描边，去掉 scale。


## 墙反馈（失败 / 空 / 重试）

| 状态 | Do | Don't |
| --- | --- | --- |
| 刷新失败 | 屏上有卡片 → 保留 + toast；屏上为空才画 error 态 | 清空 `#grid` 只留一句「加载失败，请刷新」 |
| 错误态 | icon + 文案 + 语义色（`.empty.is-error`）+ `role="alert"` + 「重试」`[data-wall-retry]` | 只有红色 / 只有错误码 / 无下一步 |
| 加载更多失败 | 底部留「重试」`[data-wall-retry-more]`（`loadMoreFailed` 挡住 finally 隐藏） | 只 `console.error` 静默卡住 |
| 空态 | 按原因分文案：回收箱 / 搜索（带词 + 「清除搜索」）/ 类型筛（「显示全部」）/ 真空库（说明内容怎么来） | 一律「没有匹配的记录」且无下一步 |
| 骨架屏 | **不装**。`wall_load` 均值 ~67ms，骨架只会闪 | 为「完整」预渲染占位 DOM |

规则：重试 / 清除动作一律委托（`[data-wall-retry]` / `[data-wall-retry-more]` / `[data-wall-clear]`），挺过 masonry 重建（禁止每渲染绑一遍）。卡片上屏时 `layoutMasonry` 清掉所有非卡片子节点（包括 boot 的「加载中…」`.empty`），否则占位会留在卡片底下。

## 紧凑布局 + 锚定 popover

| Do | Don't |
| --- | --- |
| 卡片只露：类型色 badge · 可选 ×N · **一个**时间 | 「首次 / 最近捕获」次要时间行 |
| 时间线 popover **贴着 ×N** 弹出（可上下翻转） | 固定屏幕底大 sheet 脱离上下文 |
| 轻 scrim + 毛玻璃小卡 | 重遮罩抢戏 |
| transform-origin 来自触发点 | 从屏幕中心 scale |

## 片段折叠（已移除）

**已回滚。** substr fold 过于激进，误伤独立剪贴片段。主规则仅 **exact content_hash latest-alive**。历史被 soft-delete 的条目在启动时按 operation_logs(`source=substr_fold`) 自动 restore。

