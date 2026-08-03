# Keepsake

**你的剪贴板记忆。**

Keepsake 是面向个人 Mac 的剪贴板历史产品：本机守护进程静默捕获，浏览器里检索与预览，图片 OCR 可检索，备份进 iCloud 云盘（CloudDocs）——**无需 App 签名、无第三方云。**

> 仓库目录与部分可执行文件名仍可能显示历史代号 `ClipView` / `ClipFlow`。**产品品牌统一为 Keepsake。**

---

## 它是什么

| 你感知到的 | 背后 |
| --- | --- |
| 复制即归档 | `ClipFlowServer` 守护进程监听系统剪贴板 |
| 浏览器打开即用 | 本机 Web UI · `http://localhost:8080` |
| 图里的字也能搜 | Apple Vision 离线 OCR |
| 换机/重装不丢 | iCloud Drive · CloudDocs 在线 SQLite 备份 |

**不是** 又一个 ClipXxx 工具列表；**是** 个人剪贴板的记忆层。

---

## 能力一览

- **捕获**：文本 / HTML / 图片等；变更即入库  
- **浏览**：Material 3 风格瀑布流；类型筛选；服务端搜索  
- **图片**：列表缩略图（`size=thumb`）；点击 lightbox 看原图（`size=full`）  
- **OCR**：中英识别，限高可滚动展示，写入可检索字段  
- **实时**：SSE 推送新条目，增量合并而非整表重刷  
- **规模**：游标分页 + 列表不拉 BLOB + `content-visibility`  
- **备份**：CloudDocs · `sqlite3_backup` · latest + 滚动快照 · Web 侧栏控制 / 恢复  
- **隐私**：数据默认在 `~/Documents/ClipFlow/`；备份在你的 iCloud 云盘目录下  

---

## 架构（当前真源）

```text
Keepsake (product)
├── ClipFlowServer          # headless daemon (SPM product)
│   ├── ClipboardMonitor    # pasteboard + OCR
│   ├── DatabaseManager     # SQLite3 · cursor pages · online backup API
│   ├── WebServer           # :8080 · REST + SSE + static UI
│   └── CloudDocsBackupService
├── web/index.html          # 浏览器控制面
└── LaunchAgent             # 登录自启（可选）
```

| 层 | 选择 |
| --- | --- |
| 语言 | Swift 5.9 · macOS 13+ |
| 存储 | 原生 SQLite3（**非** DuckDB） |
| 网络 | Network.framework · 自研 HTTP/1.1 |
| OCR | Vision |
| 备份 | iCloud Drive CloudDocs（**无** App iCloud entitlement） |
| CI | `swift build` + `node --test tests/masonry.test.mjs` |

历史文档若仍写 DuckDB / 仅 Xcode App，以本 README 与 `Package.swift` 为准。

---

## 快速开始

### 要求

- macOS 13+  
- Xcode / Command Line Tools（`swift`）  

### 构建并运行守护进程

```bash
git clone https://github.com/DavidMusk93/ClipView.git
cd ClipView

swift build -c release --product ClipFlowServer
./.build/release/ClipFlowServer
```

浏览器打开：**http://localhost:8080**

### 登录自启（可选）

仓库内 `com.davidmusk.clipflow.plist` 可装到 `~/Library/LaunchAgents/`（路径按本机 `.build` 调整）。  
安装后用 Web UI 或 API 管理备份，无需再开 Xcode。

### 开发调试

```bash
swift build --product ClipFlowServer
node --test tests/masonry.test.mjs
```

---

## 数据与备份位置

```text
~/Documents/ClipFlow/
├── clipflow.db                 # 主库
├── config/backup.json          # 备份开关与策略
└── Logs/                       # 可选日志

~/Library/Mobile Documents/com~apple~CloudDocs/ClipFlow/backup/
├── latest/{clipflow.db, MANIFEST.json}
├── snapshots/YYYYMMDD-HHmmss/
└── STATUS.json
```

Finder：**iCloud 云盘 → ClipFlow → backup**

Web：右上角 **备份** 侧栏 → 开关 / 立即备份 / 从快照恢复。

---

## HTTP 摘要

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/` | Web UI |
| GET | `/api/clips?limit&cursor&q` | 游标分页 · `{ items, nextCursor }` |
| GET | `/api/image?id=&size=thumb\|medium\|full` | 多档图片 |
| GET | `/api/events` | SSE |
| GET | `/api/backup/status` | 备份状态 |
| POST | `/api/backup/config` | `{ "enabled": true }` |
| POST | `/api/backup/run` | 立即备份 |
| POST | `/api/backup/restore` | `{ "id": "latest" \| snapId }` |

---

## 产品与协作

- 产品名：**Keepsake**  
- 品味与 agent 约定：见仓库根目录 **[AGENTS.md](./AGENTS.md)**  
- 许可证：MIT  

---

**Keepsake** — 剪贴板会忘；记忆不必。
