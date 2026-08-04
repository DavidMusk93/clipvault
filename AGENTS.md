# Keepsake · AGENTS.md

给 **人类协作者与编码 agent** 的仓库约定。改产品前先读本节；与全局 `~/.grok/AGENTS.md` / nmem 冲突时：**本仓库产品层以本文为准**。

---

## 1. 产品身份

| 项 | 值 |
| --- | --- |
| **产品名** | **Keepsake** |
| **一句话** | 你的剪贴板记忆 |
| **定位** | 个人 Mac 上的剪贴板记忆层：捕获 · 检索 · OCR · 本机 Web · iCloud Drive 备份 |
| **不是** | 企业协同剪贴板、云笔记、又一个 `ClipXxx` 工具箱皮肤 |
| **仓库历史名** | GitHub / 目录可能仍叫 `ClipView`；二进制/模块可能仍叫 `ClipFlow*` |
| **品牌规则** | **对外文案、README、窗口标题、用户可见 UI 字符串 → Keepsake**。内部 SPM target / LaunchAgent label 可渐进迁移，禁止再引入新的「ClipView 产品名」文案 |

命名否决过的方向（不要回潮）：

- `ClipView` / `ClipFlow` 当**品牌**（可用作遗留路径/进程名）  
- `XxxView` / `ClipManager` 等组件腔  
- 为「一眼功能」牺牲独立产品感  

---

## 2. 产品 taste（Owner）

Owner 要的是 **独立产品气质 + 终局工程**，不是 demo 合集。

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

### 2.3 工程（always SOTA / 终局）

| Do | Don't |
| --- | --- |
| 一次做对：分页、多档图、备份一致性、CI 对齐生产路径 | P0/P1 菜单式半吊子交付 |
| 生产真源：`Package.swift` → `ClipFlowServer` + `web/index.html` | 文档还写 DuckDB/Xcode 当唯一路径却不维护 |
| 万级可想：cursor、无列表 BLOB、虚拟化/content-visibility | `LIMIT 10000` 一次塞 DOM |
| SQLite 备份用 `sqlite3_backup`；CloudDocs 固定目录 | 热 copy 开着的 db；依赖未签名的 App ubiquity 容器当 daemon 方案 |
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
| 可写可执行：直接改、构建、验证、及时 push（用户已授权类任务时） | 用 Ask 模式推脱简单修复；列半成品选项让用户挑 |
| 非琐碎改动：先对齐架构再动手 | 边想边堆、只改表面文案假装品牌迁移完成 |
| 用户可见字符串优先中文（UI）；标识符可英文 | UI 英文硬编码一堆无必要 |
| 改完更新 README / 本 AGENTS 若触及产品边界 | 架构已 SQLite 却 README 仍 DuckDB |

---

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

改 Keepsake 相关呈现时至少碰：

- [ ] `README.md` 标题与叙事  
- [ ] `web/index.html` 标题、顶栏、备份侧栏文案  
- [ ] 用户可见 toast / 空状态  
- [ ] 本 `AGENTS.md` 若规则变化  
- [ ] **不必**强行一次改完 LaunchAgent label / 可执行文件名（可跟版本做）  

---

## 5. 一句话给 agent

**Keepsake = 个人剪贴板记忆产品。**  
做终局、像产品、本机优先、列表轻预览重、备份可恢复。  
历史文件夹名 `ClipView` 不定义品牌。
