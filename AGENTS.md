# ClipVault · AGENTS.md

给 **人类协作者与编码 agent** 的仓库约定。改产品前先读本节；与全局 `~/.grok/AGENTS.md` / nmem 冲突时：**本仓库产品层以本文为准**。

---

## 1. 产品身份

| 项 | 值 |
| --- | --- |
| **产品名** | **ClipVault** |
| **一句话** | 你的剪贴板记忆 |
| **定位** | 个人 Mac 上的剪贴板记忆层：捕获 · 检索 · OCR · 本机 Web · iCloud Drive 备份 |
| **不是** | 企业协同剪贴板、云笔记、又一个 `ClipXxx` 工具箱皮肤 |
| **仓库历史名** | GitHub / 目录可能仍叫 `ClipView`；二进制/模块可能仍叫 `ClipFlow*` |
| **品牌规则** | **对外文案、README、窗口标题、用户可见 UI 字符串 → ClipVault**。内部 SPM target / LaunchAgent label / 数据目录可仍为 ClipFlow* 或历史 Keepsake 路径；禁止把 ClipView/ClipFlow 当产品品牌回潮 |

命名否决过的方向（不要回潮）：

- `Keepsake` 当**现行品牌**（历史文案/路径可残留；新用户可见字符串一律 ClipVault）  
- `ClipView` / `ClipFlow` 当**品牌**（可用作遗留路径/进程名）  
- `XxxView` / `ClipManager` 等组件腔  
- 为「一眼功能」牺牲独立产品感  

---

## 2. 产品 taste（Owner）

Owner 要的是 **独立产品气质 + 终局工程**，不是 demo 合集。

**可执行视觉真源**：[`docs/design-taste.md`](docs/design-taste.md)（类型标签色、ops 来源色、品牌 Honey）。
改 badge / 来源色必须先改该文档，再同步 Web + Android，禁止一端私调。

### 2.0 作者 taste → 个性化设计语言（持续沉淀）

Owner 的审美与取舍不是会话闲聊，而是 **产品设计语言的原材料**。Agent / 协作者必须双写沉淀：

| 落点 | 写什么 | 何时写 |
| --- | --- | --- |
| **本仓库** | `AGENTS.md` §2（叙事/体验/工程原则）；可执行 token 进 [`docs/design-taste.md`](docs/design-taste.md) | 用户明确偏好、否决某风格、锁定色/动效/文案气质时 |
| **nmem** | `preference` / `decision` / `learning`：一句话结论 + 证据（原话/commit）+ 下次该怎么做 | 同上；跨会话、跨机恢复时优先 `memory_search` ClipVault/taste |

| Do | Don't |
| --- | --- |
| 每次可复用的 taste 判断写进文档或 nmem（或两者） | 只改一处 UI 颜色却不回写真源 |
| 冲突时：**更新文档/nmem 为新裁决**，旧记忆 supersede 或标注过时 | 靠「我记得上次好像…」口头延续 |
| 逐渐收敛为稳定语言：色板、密度、动效禁区、文案语气、跨端一致性 | 每轮按 agent 默认审美重开一盘 |

**目标**：随着批评与取舍累积，ClipVault 形成 **Owner 个性化的设计语言**，而不是通用 Material/工具腔皮肤。

**产品哲学（演进新能力前必读）**：nmem `clipvault_design_philosophy_layered_memory_20260814`  
一句话：正确性交给浏览器引擎，陪伴感留在产品里，运行时体验不污染 capture。五层：Capture / Judgment / Archive / View / Runtime。

### 2.1 品牌与叙事

| Do | Don't |
| --- | --- |
| 像 Paste / Raycast：短名 + 副标题解释能力 | 用模块名当产品名（`ClipboardMonitor UI`） |
| 中文说明可以暖而克制（「记忆」「留存」） | 堆 emoji 营销号文案、假「AI 驱动」 |
| 一个主品牌贯穿 daemon / Web / 备份 | 双品牌分裂（UI 一个名、服务另一个名当对外品牌） |

### 2.2 体验

| Do | Don't |
| --- | --- |
| 静默捕获；打开 Web 即用 | 强迫先配一堆才能看历史 |
| 列表轻（thumb）；预览重（lightbox full） | 列表直接灌原图 |
| 交互不抖：hover 不做几何位移；展开不重排整墙 | `translateY` hover + 全量 remount |
| OCR 限高可滚动，不靠 `<details>` 撑布局 | 点一下 OCR 整页 masonry 重排 |
| 备份/恢复有状态、可点、路径说人话 | 只有日志里才知道备份成败 |
| **列表变更差分渲染 + 保持 scroll/cursor**（删/恢复卡片） | 删一条就 `innerHTML=''` 全量 rebuild 回顶 |
| **滚动丝滑**：图框锁高；禁止 `img.onload → rebuildFromData`；append 离屏量高 | 滑动中瀑布流全量 rebalance（社交流不会这么做） |
| **URL 归档（save useful）**：手动「归档网页」→ WKWebView+Readability；预览消毒不可点 | 前端 CORS fetch 当归档；自动爬每一个链接 |
| **View**：弹层 iframe `src=/api/archive/view?embed=1`（真文档，浏览器引擎排版）；可再开新标签 | srcdoc / Turndown 自绘；毛玻璃+transform 包 iframe；只弹出孤立 tab |
| **归档后同一按钮变「查看」**（同槽同尺寸）；已归档禁止再点「归档网页」 | 另塞一颗小「查看」；归档按钮归档后仍可点 |
| **View 阅读壳**：同域文档内注入 TOC + 进度；阅读位置只进 IndexedDB | 把滚动位置写入 SQLite；srcdoc 里自绘目录；父页面跨 iframe 记进度 |
| 删/恢复后 **SSE 差分**（`applyRemoteClipRemoval`）；禁止 `clip_deleted → fetchPage(reset)` | SSE 全量 reset 把 scroll 打回顶部（真因） |

### 2.3 工程（always SOTA / 终局）

| Do | Don't |
| --- | --- |
| **Capture payload 不可变**；评价：`user_evaluations` append-only；星级可改；紧凑星在 sheet header；铅笔入口；历史时间线；禁主卡片 body | 阶段芯片；评价 strip 进 masonry；为大星行浪费 sheet 垂直空间 |
| 一次做对：分页、多档图、备份一致性、CI 对齐生产路径 | P0/P1 菜单式半吊子交付 |
| 生产真源：`Package.swift` → `ClipFlowServer` + `web/index.html` | 文档还写 DuckDB/Xcode 当唯一路径却不维护 |
| 万级可想：cursor、无列表 BLOB、虚拟化/content-visibility | `LIMIT 10000` 一次塞 DOM |
| SQLite 备份用 `sqlite3_backup`；CloudDocs 固定目录 | 热 copy 开着的 db；依赖未签名的 App ubiquity 容器当 daemon 方案 |
| **备份增量是核心**：CAS size-match skip；只补 missing/partial | **每轮 forceFull 重拷全部 blob**（偷懒/无能；GDrive File Provider 会 EDEADLK） |
| SQLite 运行时按 `sqlite-runtime-tricks` skill：WAL / busy_timeout / ANALYZE / FTS5 / 分批清理 | 裸 `sqlite3_open` + 全表 `LIKE '%q%'` + 一次 `DELETE` 清库 |
| CI = 能绿的真构建（`swift build` + 单测） | 为旧 xcodeproj+DuckDB 殉葬 |

**SQLite 运维 skill（agent 必读）**：本机 `~/.trae-cn/skills/sqlite-runtime-tricks/` 与仓库 `.trae/skills/sqlite-runtime-tricks/`（同源）；源文 [jvns 2026-07](https://jvns.ca/blog/2026/07/17/learning-about-running-sqlite/)。改 `DatabaseManager` / 备份 / 搜索前先加载。

### 2.4 隐私与本机

| Do | Don't |
| --- | --- |
| 默认数据在用户目录；备份在用户自己的 iCloud Drive | 未说明就上传第三方 |
| 剪贴板当敏感数据：日志脱敏、不写 nmem 密钥 | 把 db 路径+密钥贴进 chat/nmem |
| 个人本机优先：能 CloudDocs 就别为签名折腾 | 为「正式容器」阻塞个人可用备份 |

### 2.5 协作与 agent 行为（本仓库）

| Do | Don't |
| --- | --- |
| 可写可执行：直接改、构建、验证、**及时 commit + push**（用户已授权类任务时） | 用 Ask 模式推脱简单修复；列半成品选项让用户挑 |
| 非琐碎改动：先对齐架构再动手 | 边想边堆、只改表面文案假装品牌迁移完成 |
| 用户可见字符串优先中文（UI）；标识符可英文 | UI 英文硬编码一堆无必要 |
| 改完更新 README / 本 AGENTS 若触及产品边界 | 架构已 SQLite 却 README 仍 DuckDB |
| 可独立描述的单元完成后立刻入库并推远程 | 长时间本地脏树 / 只 stash 不提交 / 攒大批再推 |

#### 改动及时提交并推送（硬约束）

| 规则 | 说明 |
| --- | --- |
| **及时 commit** | 完成一个可独立描述的单元（修 UI / 同步 / 单 API / 一批 docs）后 **立即** `git commit`，不要攒大批未提交改动。 |
| **及时 push** | commit 后 **尽快** `git push origin <branch>`（默认 `master`）。推送失败须在回复里说明，不得假装已推送。 |
| **粒度** | 一步一提交；message = short subject + 空行 + 完整句子说明 why。 |
| **不混装** | 无关重构、无关文件不要塞进同一 commit。 |
| **禁止** | 用长期 `git stash` 代替提交；同步 remote 前若必须 stash，pull 后应恢复或明确丢弃，**不得**留下「忘记提交的本地 WIP」。 |

推荐节奏：

```text
改完一个单元 → 验证 → git status/diff → commit → push → 再开下一单元
```

---


### 前端部署门禁（必过）

改 `web/index.html` 后、**push / 同步到本机 :8080 前**必须：

```bash
./scripts/check-frontend.sh
# 或: node --test tests/*.test.mjs
```

`tests/frontend-smoke.test.mjs` 会用 `node --check` 校验主脚本语法，并回归 `anyAvail` 等易被注入截断的表达式。**语法不过禁止上线。**

## 3. 技术真源（防过时）

| 层 | 真源 |
| --- | --- |
| 构建 | `swift build --product ClipFlowServer` |
| UI | `web/index.html`（由 daemon 读盘提供） |
| 库 | `~/Documents/ClipFlow/clipflow.db` |
| 备份 | CloudDocs `…/ClipFlow/backup/` + `CloudDocsBackupService` |
| CI | `.github/workflows/xcode-build.yml`（现为 SPM + Node tests，文件名历史遗留） |
| 废弃叙述 | DuckDB 主存储、仅靠 `ClipFlow.xcodeproj`+`libDuckDB.a` 的安装说明 |

模块深度约定（仍适用）：

- **Monitor**：捕获与 OCR，不写 HTTP  
- **DatabaseManager**：存储与备份原语（含 `sqlite3_backup`）  
- **WebServer**：协议与静态面，不塞业务特例  
- **CloudDocsBackupService**：备份策略与快照生命周期  

---

## 4. 改品牌时的检查清单

改 ClipVault 相关呈现时至少碰：

- [ ] `README.md` 标题与叙事  
- [ ] `web/index.html` 标题、顶栏、备份侧栏文案  
- [ ] 用户可见 toast / 空状态  
- [ ] 本 `AGENTS.md` 若规则变化  
- [ ] **不必**强行一次改完 LaunchAgent label / 可执行文件名（可跟版本做）  

---

## 5. 一句话给 agent

**ClipVault = 个人剪贴板记忆产品。**  
做终局、像产品、本机优先、列表轻预览重、备份可恢复。  
历史文件夹名 `ClipView` 不定义品牌。

---

## Android 客户端

| 项 | 值 |
| --- | --- |
| 路径 | `android/` |
| 定位 | 备份阅读器 + 前台粘贴/分享；**不做**后台剪贴板监听 |
| 数据 | SAF 读优先 `ClipVault/cvbak`，兼容 `ClipVault/backup` / `Keepsake/backup`（与 Mac GDrive fan-out 一致） |
| 发布 | `.github/workflows/android-apk.yml` → artifact / tag Release |

---

## 6. 数据目录铁律（incident 2026-08-11）

**真库默认：`KEEPSAKE_HOME=~/Documents/ClipFlow`（`clipflow.db` + `blobs/`）。**  
`~/Library/Application Support/Keepsake` 只是历史/回落路径；**无 env 裸启会打开空库，UI 像「历史全丢」。**

### 禁止

- `nohup ClipFlowServer &` / 直接跑二进制替代 LaunchAgent  
- `launchctl` 重启后不跑校验  
- 未确认路径就对 db 做删除、覆盖、migration「修复」  

### URL 双面展示（禁止再拆丢）

| 面 | 行为 |
| --- | --- |
| **canonical** | `openHref` 整链 **单行**（`.url-display` nowrap 横滑） |
| **parse** | pretty 正文多行：`host/path` + `# query` 键值 + `# hash` |
| **打开** | 仅按钮 → `requestOpenExternalUrl`（确认 / 成人门禁） |

**禁止**只留单行不要解析，或只展开参数却做成可点 `<a>`。改 URL 展示必须同时跑 `tests/text-format.test.mjs` 的 dual surface 用例。

### 必须

```bash
# 唯一支持的重启 / 换二进制
./scripts/deploy-server.sh          # build release + install + launchctl + verify
# 或已装好二进制时：
./scripts/restart-clipflow.sh
./scripts/verify-data-home.sh       # 失败 = 禁止告诉用户「已恢复」
```

### 用户报「历史丢失」时 30 秒分流

```text
对比:
  ~/Documents/ClipFlow/clipflow.db          体积 / sqlite COUNT(*)
  ~/Library/Application Support/Keepsake/clipflow.db
若 Documents 大而 API 空 → 错 home → restart-clipflow.sh
若两边都空 → 再查 ~/ClipVault-Backups/Quark/backup/snapshots/
```

完整复盘：`docs/incident-20260811-wrong-data-home.md`

---

## 7. 备份增量铁律（incident 2026-08-13 · GDrive EDEADLK）

**增量是核心能力。对任何目标（含 quark / 本地 staging）每周期全量重拷 = 偷懒 / 无能，禁止。零例外。**

### 背景（必须记住）

| 项 | 事实 |
| --- | --- |
| 表象 | `blobs 校验失败 missing=N` + `Resource deadlock avoided`（EDEADLK） |
| 真因 | File Provider（`~/Library/CloudStorage/GoogleDrive-*`）不是块设备；高频 create/unlink + `F_FULLFSYNC` 把域楔死 |
| 直接触发 | 旧逻辑对 **gdrive/icloud 每轮 `forceFullCopy=true`**（为修 clonefile 假成功而矫枉过正） |
| 对照 | iCloud 增量正常；夸克本地 APFS 暂存可 full；GDrive 旧路径 `ClipVault/backup` 楔死后连 mkdir 也 EDEADLK |
| 修复 | commit `3cb4d9a`：size-match 增量 + cloudSafe + 新根 `ClipVault/cvbak` |

### 禁止（agent / 代码 / 运维）

| 禁止 | 说明 |
| --- | --- |
| **任何目标每轮 forceFull** | `forceFullCopy=true` **一律非法**（**含 quark / 本地 staging**；无白名单） |
| **CloudStorage 路径 `F_FULLFSYNC`** | 无磁盘 barrier 语义，只会加压 File Provider 协调路径 |
| **为「保险」重写全部 CAS** | 完整度靠 **verify + 只修 missing/sizeMismatch**，不靠全量重拷 |
| **把 bulk full 当默认** | 「简单粗暴全拷」在 PR/review 直接打回 |

### URL 双面展示（禁止再拆丢）

| 面 | 行为 |
| --- | --- |
| **canonical** | `openHref` 整链 **单行**（`.url-display` nowrap 横滑） |
| **parse** | pretty 正文多行：`host/path` + `# query` 键值 + `# hash` |
| **打开** | 仅按钮 → `requestOpenExternalUrl`（确认 / 成人门禁） |

**禁止**只留单行不要解析，或只展开参数却做成可点 `<a>`。改 URL 展示必须同时跑 `tests/text-format.test.mjs` 的 dual surface 用例。

### 必须

| 必须 | 说明 |
| --- | --- |
| **增量 CAS 镜像** | 目标已存在且 `size` 一致且 `size > 0` → **skip** |
| **只修坏的** | missing / size 0 占位 / sizeMismatch → 单文件 rewrite + 退避 |
| **forceFull 零例外** | 代码里若传入 true 必须拒绝/降级为增量；**quark 也不例外** |
| **cloudSafe 写路径** | gdrive/icloud：禁 FULLFSYNC；流式写或等价；EDEADLK 退避；禁止紧循环 mass `copyItem` |
| **最新快照面** | 灾备主面是 `latest/` + `blobs/` CAS；named snapshot 可 best-effort，**不得**为 snap 失败否定已成功的增量 latest |
| **路径楔死** | 换干净子树（如 `cvbak`）或本地暂存 + 诚实 `ok:local_staging`；**禁止**对 wedged 树死磕全量 |

### 代码锚点

```text
CloudDocsBackupService.syncBlobsToCAS
  forceFullCopy: false  → 全目标强制（含 quark）；true 会 log 拒绝并降级
  cloudSafe: true       → gdrive + icloud
  size-match continue   → 增量核心

BackupDestinations.backupRoot(gdrive)
  优先 My Drive/ClipVault/cvbak   # 避开 wedged backup/
```

### 自检（改备份相关代码后）

```bash
# 1) 源码不得再出现 forceFullCopy: true（任何目标，含 quark）
rg -n 'forceFullCopy:\s*true|forceFull\s*=\s*\(dest' ClipFlow/
# 期望：无匹配；或仅有「REFUSED forceFullCopy」拒绝分支

# 2) 跑一次备份：各 dest 日志应为 +0/repairK 或小增量，不是 +N 全量
# [Backup] dest=gdrive|quark|icloud ok … blobs=N +0/repair0   ← 稳态
# +N 仅允许「目标几乎为空、首次灌库」的一次，禁止周期性全量
```

### 错误心态（写进复盘）

| 错误 | 正确 |
| --- | --- |
| 「全量最稳」 | 全量最稳的是 **语义**（sqlite3_backup 快照 + CAS 校验），不是 **每轮字节重传** |
| 「File Provider 不靠谱所以狂写」 | 越狂写越楔死；靠增量 + 校验 + 退避 |
| 「clonefile 假成功 → 永远 full copy」 | clonefile 禁用于云目标即可；**增量 full-byte 只针对缺失文件** |
| 「quark 是本地盘可以全量」 | **不行**。本地也增量；full 浪费 IO，且会把「全量习惯」带回云目标 |

相关 nmem：`clipvault_research_gdrive_fileprovider_edeadlk_20260813` · `clipvault_fix_gdrive_edeadlk_cvbak_20260813`

---

## 8. 链接与 HTML 安全门禁（公开场合 · 成人内容）

**卡片是预览，不是浏览器。禁止把剪贴板 HTML/URL 渲染成可误触的可点击链接。**

### 问题（incident 2026-08-13）

| 问题 | 原因 / 风险 |
| --- | --- |
| HTML 卡片黑底白字 | Chrome 暗色页 / 选区复制带 `style=background:#000;color:#fff` 或 `bgcolor`，旧 sanitize 只清部分标签 |
| 成人 URL 误触 | 公开场合一点即 `window.open` 伤风败俗 |
| 可点击 `<a href>` / `url-canonical` | 预览区像网页，误触即外跳 |

### 禁止

| 禁止 | 说明 |
| --- | --- |
| 卡片内可导航 `<a href>` | 富文本 / pretty URL / 任意 innerHTML 注入 |
| 无确认 `window.open` 外链 | 尤其成人/敏感域名 |
| 信任剪贴板 `style`/`bgcolor`/`color` | 一律剥离后再渲染 |
| 用「方便」恢复一键裸开链接 | PR 直接打回 |

### URL 双面展示（禁止再拆丢）

| 面 | 行为 |
| --- | --- |
| **canonical** | `openHref` 整链 **单行**（`.url-display` nowrap 横滑） |
| **parse** | pretty 正文多行：`host/path` + `# query` 键值 + `# hash` |
| **打开** | 仅按钮 → `requestOpenExternalUrl`（确认 / 成人门禁） |

**禁止**只留单行不要解析，或只展开参数却做成可点 `<a>`。改 URL 展示必须同时跑 `tests/text-format.test.mjs` 的 dual surface 用例。

### 必须

| 必须 | 说明 |
| --- | --- |
| **presentation sanitize** | 对 DOM **全部元素**去 style/bgcolor/color/face…；CSS 再 `background:transparent !important` |
| **neutralize anchors** | `<a>` → 不可点 `span.url-inert`（文案保留） |
| **URL 展示** | `div.url-display` 纯文本，**不是** `<a>` |
| **打开路径唯一** | `requestOpenExternalUrl(href)`；仅 http(s) |
| **成人/敏感确认** | `isAdultRiskUrl` 命中 → 强确认文案后再 open；未命中也要 confirm（显式按钮意图） |
| **事件兜底** | capture 阶段拦截 `.m3-card a[href]` 误点 |

### 自检

```bash
rg -n 'url-canonical|window\.open\(' web/index.html
# 期望：无 url-canonical；window.open 仅出现在 requestOpenExternalUrl 内
rg -n 'requestOpenExternalUrl|isAdultRiskUrl|url-display|transparent !important' web/index.html
node --test tests/notes-render.test.mjs tests/frontend-smoke.test.mjs
```

### 代码锚点

```text
web/notes-render.mjs     sanitizePresentation · neutralizeAnchors
web/index.html           renderNotesFragment · requestOpenExternalUrl · url-display
AGENTS.md §8             本门禁
```

相关 nmem：`clipvault_gate_url_html_safety_20260813`


