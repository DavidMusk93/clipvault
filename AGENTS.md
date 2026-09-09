# ClipVault · AGENTS.md

给人类协作者和编码 agent 的**仓库法**。改产品前读本文。与 `~/.grok/AGENTS.md` / nmem 冲突时：**本仓库产品层以本文为准**。

本文是契约，不是会话流水账。引用用**章节名**，禁止 `§2.3.1` 这类会随插入而漂移的编号。

```text
                    ClipVault 仓库法
                           |
          +----------------+----------------+
          |                |                |
       硬约束            总图              领域
     没做完不算        先对层再写        一节一块
          |                |                |
          |         分层 / 端口 /          |
          |         三平面 / 模块          |
          |                                |
          +------------+-------------------+
                       |
        捕获  墙  笔记  会话  归档  同步  备份  Metrics  HTTP
                       |
                    运维 / 附录
              启动 · 门禁 · commit · 指针

事故叙事 → docs/incident-*     token → design-taste.md
机制/误判 → nmem               本文只留不变式 + 拓扑 + 禁止
```

每节形状固定：**不变式 → ASCII 拓扑 → 短禁止 → 去哪改**。细节不进本节。

```text
改本文
  新能力      先对「记忆分层」，再写入对应领域节
  新不变式    改该节 ASCII 或加一行禁止
  新指标      ## Metrics 表加 name
  新事故      docs/incident-YYYYMMDD-*.md + 附录一行
  禁止        往硬约束堆 Do/Don't；同一段复制到多节；恢复 § 编号
```

---

## 硬约束

1. **改动及时提交并推送。** 可独立描述的单元验证完 → `git commit` → `git push origin <branch>`（默认 `master`）。禁止攒脏树、只 commit 不 push、用会话结束当「以后再推」。push 失败必须写明。
2. **nmem 不是流水账。** 写可复用机制：一句话结论 + ASCII + 证据。禁止聊天摘要。
3. **开发迭代 = metrics-based optimization。** 卡顿/抖动/白屏先读本机 `ui-metrics.db`（`#debug` / `GET /api/ui-metrics/recent`）。归因不够：**先补点，再改**。禁止让用户翻红行。未用同一指标对照不得宣称丝滑。

---

## 身份

| 项 | 值 |
| --- | --- |
| 产品名 | **ClipVault** |
| 一句话 | 遇到的留下，想到的写下 |
| 是 | 个人记忆：静默捕获世界 + 主动写下自己 |
| 不是 | 企业协同剪贴板、Notion 替代、又一个 `ClipXxx` 工具箱 |
| 对外品牌 | 文案 / README / 窗口标题 / UI 字符串 → **ClipVault** |
| 对内可残留 | 目录 `ClipView`、二进制 `ClipFlow*`、数据路径 Keepsake |
| 视觉真源 | [`docs/design-taste.md`](docs/design-taste.md)（改色先改它，再 Web + Android） |

否决回潮：`Keepsake` 当现行品牌、`ClipView`/`ClipFlow` 当对外品牌、`XxxView` 组件腔。

品味落点：可执行 token → `docs/design-taste.md`；跨会话裁决 → nmem。禁止只改一处颜色却不回写真源。

---

## 总图

### 记忆分层（新能力先对层，再写代码）

```text
  世界 ──复制──► [capture]  clipboard payload     不可变  content_hash
                      │
                      ├── [judgment]  pin / eval / clip_link     append-only ops
                      │
                      ├── [archive]   WKWebView+Readability      CAS 闭包
                      │                 ├─ 用户浏览器 tab（cookie / 系统或扩展代理）
                      │                 └─ 归档 WKWebView（独立 store；无系统代理则 SOCKS :2080）
                      │
                      └── [compose]   type=note + compose_ops    可变投影
```

Capture 禁止就地改成笔记。Compose 禁止写成第二套剪贴板。

### 进程与端口（浏览器只认一个 TCP 口）

```text
  Chrome / Safari
       │  HTTPS  ALPN h2
       v
  https://127.0.0.1:8080          clipvault-http   Rust  hyper+rustls
       │                          唯一 TCP 监听
       │  HTTP/1.1 流式（非浏览器口）
       v
  $KEEPSAKE_HOME/run/http.sock    ClipFlowServer   Swift
       │                            ├─ 剪贴板 / Vision OCR / SQLite
       │                            ├─ CloudDocs 同步 + 备份
       │                            └─ loopback 反代 /trae → :9488
       │
       ├─ 本机 CA  tls/ca.pem  → login keychain trustRoot
       │                         scripts/trust-local-https.sh
       │
       └─ GET /trae/?embed=1 ──► 127.0.0.1:9488   trae_hooks（DuckDB）
                                 浏览器禁止直开 :9488
```

禁止：第二浏览器端口、明文 HTTP/1.1 对外、SwiftNIO/BoringSSL 当边车、自签叶子不进信任链。

### 三平面（不可混）

```text
  [CAS]     blobs/{sha}.bin              内容寻址，不是协议
  [同步]    trx/{host}/{seq}.json        blob_keys = 闭包；附件 live/attach/
  [备份]    backup/hosts/{hostId}/       灾备 / hydrate 副本，不是同步总线
```

禁止：用 `ops/` 写新事务；整库覆盖当同步；对端去扫别人的 host 切片当协议。

### 模块

```text
  ClipboardMonitor    捕获 + OCR，不写 HTTP
  DatabaseManager     SQLite 原语（含 sqlite3_backup）
  clipvault-http      浏览器 TLS/h2 边
  WebServer           UDS 上的协议与静态面
  CloudDocsSyncService    每机 trx + blob_keys
  CloudDocsBackupService  快照生命周期，增量 CAS
  ArchiveBlobClosure      HTML → CAS 闭包（新资产加正则，不加 trx kind）
```

生产真源：`Package.swift` → `ClipFlowServer` + `http-front/` + `web/index.html`。文档禁止再把 DuckDB / 仅 Xcode 当唯一路径。

---

## 捕获与判断

**不变式：** capture payload 不可变；判断层 append-only。

```text
  复制瞬间
    → clipboard_items  (hash 锚定)
    → 图：CAS blob + trx upsert（ocr_text 当时为空）
    → StripOCR 成功
         → SQLite updateOCR
         → trx upsert note=ocr   只带 ocr_text，不改 content_hash
    → 启动若无 sync.ocr_replay_v1
         → 回放本机已有 ocr_text（禁止只修 going-forward）

  评价 / 星          user_evaluations  append-only；星在 sheet header
  置顶               pinned_at 投影 + trx pin/unpin；JSON 未置顶 pinnedAt:null
  关联               clip_link_ops → clip_links / link_count
                     捕获目标 exact content_hash；笔记目标 UUID
                     跨机必须 recordLocalClipLink
```

**OCR 是派生字段。** 对端 `refreshRemoteFields` 按更长文本写入。禁止假定对端会自己再跑 Vision。

禁止：改 timestamp 冒充置顶；`{...old,...item}` 留下旧 `pinnedAt`；判断写进 capture 正文；`text_hash` 当 locator。

检索：FTS `judgment_text` = 评价备注 + View 划线/评论。写完必须 `refreshJudgmentTextLocked`。禁止 `LIKE reader_ops.payload`。

---

## 墙

**不变式：** 列表轻、预览重；变更差分；滚动不重建瀑布流。

```text
  SSE /api/events
    ping / connected / update(id) / clip_deleted / clip_pinned / compose_saved
         │
         ├─ update+id  → ingestClipById  单条 prepend
         ├─ 删除/恢复  → applyRemoteClipRemoval   禁止 fetchPage(reset)
         └─ 其它       → mergeHead  /api/clips?fields=head
                          sig 不变不 rebuild
```

**UI 增量 + lazy：** 列表按稳定身份 keyed 调和。墙卡展开用 overlay / 脱离文档流。禁止每次事件整树 `innerHTML`。

| 做 | 禁止 |
| --- | --- |
| hover 不改几何 | `translateY` hover + 全量 remount |
| 图框锁高；禁止 `img.onload → rebuildFromData` | 滑动中全量 rebalance |
| 置顶排最前；翻页 cursor 只走未置顶 | 钉子混进下一页 |
| 归档后同槽按钮变「查看」 | 另塞一颗小查看；归档后仍可点归档 |

### URL 双面（只在这里写一遍）

| 面 | 行为 |
| --- | --- |
| canonical | `openHref` 整链单行（`.url-display` nowrap 横滑） |
| parse | pretty 多行：`host/path` + `# query` + `# hash` |
| 打开 | 仅按钮 → `requestOpenExternalUrl`（确认 / 成人门禁） |

禁止可点 `<a href>` / `url-canonical`；禁止信任剪贴板 `style`/`bgcolor`。改展示必须跑 `tests/text-format.test.mjs`。真源 `web/url-safety.mjs`：成人检测只匹配 host labels + path segments，禁止扫 `search`/`hash`。

---

## 笔记

**不变式：** 同一页霜层；源码 \| 预览；保存走 `compose_saved`，禁止 SSE `update` 刷墙。

```text
  #notesPanel
    ├─ 左列表     type=note  置顶复用 pinned_at（不进墙 pin rail）
    └─ 右纸面
         ├─ 打开 → 预览     新建 → 源码
         ├─ CodeMirror 6  |  marked 块 hash LRU + React 18 keyed
         └─ 弹簧揭纸  clip-path inset（数字插值，禁止 tween 字符串）
              结束必须 clearSheetInline

  多机同一篇
    保存带 parentHash → 快照 DAG → 行级 diff3（ComposeMerge）
    分叉重叠段 <<<<<<< hash（两侧排序，交换律）
    正在输入不覆盖；无 parent 的旧 trx 才 wallTs LWW
```

工具条向源码插 Markdown，不改预览 DOM。删除线 = GFM `~~文字~~`（钮 `strike` / `Mod-Shift-x`）。禁止 `overflow:hidden` 裁工具条。

禁止：Vditor / Crepe WYSIWYG；textarea 玩具编辑器；另开文档页；笔记另搞 `note_pin` trx。闲置回前台：`scheduleResync` 必须 `mergeNotesHead`。列表失败禁止开空白新笔记。

---

## 会话

**不变式：** 入口与笔记同一套霜层；加载是 `web/session-load.mjs` 的显式 FSM，不是一堆 timer。

```text
  顶栏「会话」→ #sessionsPanel iframe /trae/?embed=1
                      │
                      v
  reduce: boot → cached → connecting → resync → live
          paused 禁止 fetch；关面板 pause iframe SSE

  首屏  cv.trae.snap.v1   stale-while-revalidate（禁止当真相，禁止 cache tool 正文）
  列表  GET /api/events?view=beats    无 tool_input/tool_response（Ask 除外）
  hook  SSE stub → GET /api/event?id=  追加；列表 1s 合并
  线程  event_id keyed patch；bundle 就地手风琴
  置顶  DuckDB session_pins + POST /api/sessions/pin   不进墙 pin rail
```

**hook 禁止每次拉 `/api/sessions`+全量 events。** bundle 正文 **lazy** 加载。

列语义色：蜂蜜暖度=`fresh/today/week/old`；工具蓝=`xs/s/m/l`。禁止彩虹。默认打开 `last_ts` 最大的会话。用户气泡全展开；工具只在助手侧压缩，最后一条操作始终展开。

禁止：`setInterval` 刷 DOM；每次 hook 整页 `innerHTML`；overlay 盖住后续气泡；embed 窄宽叠成 30vh。

新加载 bug：先补 `tests/session-load.test.mjs` 再改 fetch。

---

## 归档与阅读

**不变式：** 离线归档 = 根 HTML + 它点名的全部 CAS（闭包），不是「一篇 sha」。

```text
  手动「归档网页」
    → WKWebView + Readability.js（必须在二进制同目录）
    → ArchiveBlobClosure.keys(root, html)
    → meta.closure = {v:1, root, blobs:[root, …deps]}
    → web_archive.blob_keys = blobs
    → 每个 key → live/attach

  pull：blob_keys 齐了才 apply（缺图 cursor 不推进）
  404 / 启动 repair
    hydrateBlob: live/attach ∪ backup/hosts/*/blobs ∪ backup/blobs
    齐了再发一条完整 web_archive
```

View：弹层 iframe `src=/api/archive/view?embed=1`（真文档）。图只走 `/api/archive/asset`。阅读态（划线/评论/续读）进 SQLite，不进 capture HTML，不进 IndexedDB。

抽取：Readability 前把孤儿 `img`+`figcaption` 包进 `<figure>`；保留「每条 li 有文案+图」。X Article 未解析必须 `cv-x-dropped`，禁止只凭 `cv-x-article` 当成功。

选区条：28px 浅玻璃；黄点=划线；已有划线弹出「评论 | 删除」；**删除不进评论卡**。

代码：`ArchiveBlobClosure.swift` · `enqueueArchive` / `repairArchiveClosures` / `hydrateBlob`。nmem `clipvault_archive_closure_sync_20260817`。

---

## 同步

```text
  本机事件
    → CloudDocsSyncService.recordLocal*
    → outbox → trx/{host}/{seq}.json
    → blob_keys 点名的对象 → live/attach/{sha}.bin
    → iCloud Drive 运输
    → 对端 pull apply（grow-only 字段：ocr_text 更长才写）
```

禁止：共享 CAS 当协议；备份切片当同步总线；OCR 只写本机 SQLite。

---

## 备份

**不变式：** 增量是核心。任何目标每轮 forceFull = 非法。零例外（含 quark）。

```text
  sqlite3_backup ──► backup/hosts/{hostId}/latest/
  blobs CAS
    目标已有且 size>0 且一致 → skip
    missing / size0 / mismatch → 单文件 rewrite + 退避

  gdrive / icloud
    cloudSafe：禁 F_FULLFSYNC；禁紧循环 mass copyItem
    根优先 My Drive/ClipVault/cvbak（避开 wedged backup/）
```

禁止：热 copy 开着的 db；双机写同一 `latest/`；把 bulk full 当默认。自检：`rg -n 'forceFullCopy:\s*true' ClipFlow/` 应无匹配（或仅拒绝分支）。

事故：`docs/incident-20260813` 叙事已迁出；nmem `clipvault_fix_gdrive_edeadlk_cvbak_20260813`。

---

## Metrics

本机 `ui-metrics.db`（**不同步、不含正文**）是 UI 优化输入。

```text
  感觉抖 / 白屏 / 慢
       │
       v
  GET /api/ui-metrics/recent?name=&limit=40
  GET /api/ui-metrics/summary
  #debug  Cmd-Shift-M
       │
       ├─ 能归因 (name+phase+kind+dy) → 改产品 → 同一 name 对照
       └─ 不能归因                   → 先补点，再改
```

| 症状 | name |
| --- | --- |
| 墙刷新 | `wall_fetch` `wall_merge` `wall_paint` `wall_resync` |
| 开合 sheet | `sheet_morph` `sheet_cls` `notes_cls` `trae_sessions_cls` |
| 关笔记顶栏解遮挡 | `chrome_shift` phase=close；长周期 `wall_cls` |
| 笔记输入卡 | `notes_longtask` `notes_inp` `notes_preview_ms` |
| 会话白屏 | `trae_sessions_skip` vs `trae_sessions_paint` `trae_sessions_layout` |

`notes_close.dur_ms` = 开着墙钟，不是关动画。关动画看 `sheet_morph` phase=close。Agent 自己拉 metrics。

备份徽章走 SSE `backup_status` + `?lite=1`，禁止 30s 轮询 `/api/backup/status`。

---

## HTTP / SSE 控制面

```text
  EventSource /api/events
    retry: 3000
    15s  : ping  + {"type":"ping"}
    每连接队列 32；满 → coalesce resync_required（禁止静默踢）
    onopen / visibility / online → scheduleResync → mergeHead
                                   必须同时 mergeNotesHead

  禁止 onerror 里 close()+setTimeout 当唯一重连
  HTTP/2 下 EventSource 占一条 stream
  needs_user：TraeAskFanIn 并进墙 SSE，禁止每页再挂 /trae/api/stream
```

---

## 隐私

默认数据在用户目录；备份在用户自己的云盘。剪贴板当敏感数据：日志脱敏；密钥/token **永不**进 nmem / chat / commit。

---

## Android

路径 `android/`。备份阅读器 + 前台粘贴/分享；**不做**后台剪贴板监听。SAF 优先 `ClipVault/cvbak`。发布 `.github/workflows/android-apk.yml`。

---

## 运维

### 数据目录（incident 2026-08-11）

```text
  LaunchAgent env  KEEPSAKE_HOME / CLIPVAULT_HOME
       │
       ├─ 真库（本机当前）  ~/Library/Application Support/Keepsake
       └─ 历史/文档约定    ~/Documents/ClipFlow
  无 env 裸启 → 空库 → UI 像「历史全丢」
```

禁止：`nohup ClipFlowServer &`；重启后不跑校验；未确认路径就删/覆盖 db。

「历史丢失」30 秒：

```text
  对比两处 clipflow.db 体积与 COUNT(*)
  Documents 大而 API 空 → 错 home → ./scripts/restart-clipflow.sh
  两边都空 → 再查备份 snapshots
```

完整复盘：`docs/incident-20260811-wrong-data-home.md`。

### 唯一重启路径

```bash
./scripts/deploy-server.sh        # swift + cargo clipvault-http + launchctl + verify
./scripts/restart-clipflow.sh     # 已有二进制
./scripts/verify-data-home.sh     # 失败 = 禁止说「已恢复」
# HTTPS 自检走 --noproxy '*'；浏览器 https://127.0.0.1:8080
```

### 前端门禁

改 `web/index.html` 后、push / 部署前：

```bash
./scripts/check-frontend.sh
```

门禁是 `check-frontend.sh` 的**硬编码** `node --test` 文件列表（不 glob）。新测试必须追加进脚本。`node --check` 不过禁止上线。

### commit / push

```text
改完一个单元 → 验证 → git status/diff → commit → push → 再开下一单元
```

粒度：一步一提交；message = subject + 空行 + why。不混装。回复带 HEAD、是否已 push、远程范围。

### nmem

写：机制、约束、误判根因、拓扑。不写：逐步操作、聊天压缩、一次性 PID。

每条最低：结论 · ASCII · 证据 · 下次怎么做。用 `evolves_from` 连旧条，禁止平行再写同题流水账。

---

## 协作

可写可执行：直接改、构建、验证、及时入库。非琐碎改动先对齐架构。用户可见字符串优先中文。改完若触及产品边界，更新 README / 本文。交叉引用写章节名（`AGENTS.md · 墙`），禁止 `§n`。

品牌检查：README 标题、`web/index.html` 顶栏、toast/空状态。不必一次改完 LaunchAgent label。

---

## 附录：指针

| 主题 | 去哪 |
| --- | --- |
| 视觉 token | `docs/design-taste.md` |
| 归档闭包 | nmem `clipvault_archive_closure_sync_20260817` |
| 分层哲学 | nmem `clipvault_design_philosophy_layered_memory_20260814` |
| 阅读态 SQLite | nmem `clipvault_reader_learning_layer_sqlite_20260814` |
| Compose | nmem `c2c20497-bc52-4204-99fc-34191bb98a99` |
| 评论 header | nmem `clipvault_reader_comment_header_strut_20260814` |
| 错 home | `docs/incident-20260811-wrong-data-home.md` |
| GDrive EDEADLK | nmem `clipvault_fix_gdrive_edeadlk_cvbak_20260813` |
| URL/HTML 安全 | nmem `clipvault_gate_url_html_safety_20260813` |
| SQLite 运维 | `.trae/skills/sqlite-runtime-tricks/` |
| clip-link | `docs/feature-clip-link.md` |
| 归档功能 | `docs/feature-url-archive.md` |

一句话：**ClipVault = 个人剪贴板记忆。** 终局、像产品、本机优先。历史文件夹名不定义品牌。
