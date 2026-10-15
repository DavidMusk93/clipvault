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
4. **记忆不可丢。一次错误，用户的时间线就没了。** ClipVault 是产品。墙「丢了」几乎都是序 / 翻页 / 筛选 / 回源写错，不是用户删了库。禁止用 cap、占位图、合成一张卡、只滤当前页来「看起来正常」。回归必须过 `tests/wall-integrity.test.mjs` + `tests/wall_clock_main.swift` + `tests/wall-clock.test.mjs`（`check-frontend.sh`）。

```text
  拨钟   OCR/副本 wall_ts=Date() 或 MAX(timestamp)   → 440 张挤同一秒
  砍尾   CLIENT_CAP / applyCap 丢掉 cursor 更旧行    → 翻不动
  滤错   chip 只 clientFilter 当前 30 条             → 「其他类型都丢了」
  图404  /api/image 不 hydrate；blobs→Documents 链   → 卡在、图没有
  塌列   pack 0/NaN 锁 col0；活更新不按有序列重算位置 → 墙/更新变成一条
  团块   对端 206ms 内 440 张图是 440 张卡            → 禁止合成一张
  会话   工具 LIMIT 200 砍尾                         → 历史只剩 Stop 结论
  折头   活更新 burst 折成一次 head merge（只装 30 条）→ 一次丢几千条卡片
  不动   touch 抬起 timestamp 但卡片不动 + sig 已推进  → 复制的条看着没了
  静吞   归档 suppression 窗口整段吸收（无计数）      → 窗口内复制的条目丢且查不到
  折叠   重复行硬删不写 operation_logs                → 行没了但没有任何删除记录
```

禁止：把 burst 折成 head merge（`PAGE_SIZE` 只有 30）；已知 id 报 `'have'` 早退而不跟 `timestamp` 移动；用「先吸收再等超时」的固定窗口静默吞剪贴板；硬删行不落 `operation_logs`；把 note / 有 `compose_ops` 的行当作重复折叠的输家。回归：`tests/wall-live-update.test.mjs`。

5. **墙序 = 捕获时间。** `clipboard_items.timestamp` 只表示复制发生的时刻（本机捕获或对端捕获 `wall_ts`）。OCR、副本 upsert、hydrate **不得**改这条序。只有 `kind=touch` 才 bump。策略真源 `WallClockPolicy.swift`。事故：2026-09-11 OCR 回放 `wall_ts=Date()` + `MAX(timestamp)`。

---

## 身份

| 项 | 值 |
| --- | --- |
| 产品名 | **ClipVault** |
| 一句话 | 遇到的留下，想到的写下 |
| 是 | 个人记忆：静默捕获世界 + 主动写下自己 |
| 不是 | 企业协同剪贴板、Notion 替代、又一个 `ClipXxx` 工具箱 |
| 对外品牌 | 文案 / README / 窗口标题 / UI 字符串 / 仓库 / 二进制 → **ClipVault** |
| 磁盘兼容 | 本机库仍可读 `CLIPVAULT_HOME`/`KEEPSAKE_HOME`；db 文件名 `clipflow.db`；CloudDocs 目录旧名 `ClipFlow/` 继续识别 |
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
       │  明文 :80  → h2c prior-knowledge；浏览器会走 HTTP/1.1（浏览器不做明文 h2）
       │  TLS  :443 → ALPN h2
       v
  clipvault-http                 Rust hyper     唯一 HTTP 层
       │                         唯一 TCP 监听
       │  CV01 帧（不是 HTTP）
       v
  $CLIPVAULT_HOME/run/http.sock  ClipVaultServer Swift
       │                           ├─ 剪贴板 / Vision OCR / SQLite
       │                           ├─ CloudDocs 同步 + 备份
       │                           └─ loopback 反代 /trae → :9488
       │
       └─ GET /trae/?embed=1 ──► 127.0.0.1:9488   trae_hooks（DuckDB）
                                 浏览器禁止直开 :9488
```

禁止：第二层 HTTP（UDS 上再讲 HTTP/1.1）、第二浏览器端口、SwiftNIO/BoringSSL 当边车。
禁止：一个数据目录跑两个 `ClipVaultServer`。`$CLIPVAULT_HOME/run/server.lock` 的 flock 是唯一所有权；第二个进程必须在 `DatabaseManager()` 之前退出（否则第二个会 `unlink` 掉 `run/http.sock`、抢 :80/:443，`clipvault-http` 落到 `bind Address already in use -> exit 2` 循环）。监督子进程 `stop()` 必须先等到旧 `clipvault-http` 退出再拉起新的。自检：`./scripts/verify-single-instance.sh`（server=1 且 front=1 且 lock owner==server pid）。
禁止 origin 再拼 `HTTP/1.1` 文本；handler 只走 CV01 `sendJSON`/`sendBinary`。
clipvault-http 无 `http_req` 点禁止改边车性能。
TLS 关 → :80；TLS 开 → :443。macOS 用户 LaunchAgent 绑 80/443 需要 root socket activation。

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
  clipvault-http      唯一 HTTP/2 层（h2c :80 / TLS :443）
  WebServer           CV01 origin：路由 / SSE / 静态面
  CloudDocsSyncService    每机 trx + blob_keys
  CloudDocsBackupService  快照生命周期，增量 CAS
  ArchiveBlobClosure      HTML → CAS 闭包（新资产加正则，不加 trx kind）
```

生产真源：`Package.swift` → `ClipVaultServer` + `http-front/` + `web/index.html`。文档禁止再把 DuckDB / 仅 Xcode 当唯一路径。

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
                     笔记可作 from（pair_key nh:/nn:）；跨机必须 recordLocalClipLink
```

**OCR 是派生字段。** 对端 `refreshRemoteFields` 按更长文本写入。禁止假定对端会自己再跑 Vision。

禁止：改 timestamp 冒充置顶；`{...old,...item}` 留下旧 `pinnedAt`；判断写进 capture 正文；`text_hash` 当 locator。

检索：FTS `judgment_text` = 评价备注 + View 划线/评论。写完必须 `refreshJudgmentTextLocked`。禁止 `LIKE reader_ops.payload`。

---

## 墙

**不变式：** 列表轻、预览重；变更差分；滚动不 `innerHTML` 整墙。活更新按**有序列** shortest-column **绝对定位**（改 left/top，卡身份不变），视口上方用锚点补 `scrollY`。**时间线 = 捕获时钟，不是同步到达时钟。** 渲染按**捕获日**分片：一天一块 `.day-masonry` 独立装箱，增量只重排当天（`relayoutDays`），`#dayRail` 只做锚点跳转。

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
| 对端 sync 按 **捕获** wall_ts 进同一 (timestamp,id) 序 | 用同步/OCR 的 Date() 当 timestamp |
| cursor 怎么走，clips/DOM 就怎么留 | 为「列表轻」砍 cursor 刚拉到的更旧行（CLIENT_CAP 砍尾） |
| 类型 chip 改 `type=` 后 `fetchPage({reset:true})` 走完整 keyset | 只 `clientFilter` 内存里的 30 条 |
| html chip `IN ('html','rtf')`（Notes 粘贴） | html 把 rtf 当丢失 |
| html/rtf 墙卡 `notes-rich`（表/标题/引言）；>48KB 按 id hydrate（one-shot，空体禁止循环重拉） | 当浏览器（信任 `style` / 可点 `<a>` / 远程 `<img>` / `on*` / SVG / 表单） |
| 有序列 shortest-col 绝对定位；prepend 重算坐标 | 新卡堆某一列 / flex 空列一条线 |
| 对端团块保持 N 张卡 | 合成一张 / 为团块砍尾 / 为团块拨钟 |
| 活更新 burst 按 id 分批拉全（tail 回队列）；已知 id 的 `timestamp` 变大就移动同一张卡，重排受影响的两天 | 折成一次 head merge（只装 `PAGE_SIZE` 30）/ 报 `'have'` 早退 / 推进 `lastHeadSig` 却不应用变化 |
| 卡片晚到高度（图片/表格/OCR/字体）→ `dataset.packedH` + ResizeObserver 只 repack 该列 | 全量 rebuild；预览 `img` 不限高（`.md-preview img` 必须 max-height） |
| 拉数据 burst（对端 apply / 连打复制）→ 合并成**一次** head merge（`scheduleUpdateIngest` → `wallFlushPlan`） | 每个 `update` 一次 `/api/clips?id=` + 一次重排（N 项 × N 页 = CPU 风暴） |
| 节奏条 hover/键盘划读：1px crosshair 1:1 跟指针（只写 transform）+ 读数覆在事实行上（都是绝对定位 overlay），事实 hover 只亮它点名的区间 | hover 改几何 / repack / 整墙重绘；每格留原生 `title`（双 tooltip）；288 格各开一个 tab 位 |
| 「现在」线随之前进：今天那条线由 `nowMarkerTick` 每 60s 写 `transform`（+wake/resize），parked/hidden 不跑；夜间底带几何由 `NIGHT_START/NIGHT_END` 算出 | 让「现在」停在旧时刻（头部不重绘就永不动）；夜间带写死百分比（12.5% = 只盖到 03:00，与「夜间」事实到 06:00 矛盾）；用 `left` 移动它（会触发 layout） |
| **header 数字来自 store**：`GET /api/clips/days` 按捕获日返回全量聚合（total / byType / 288 个五分钟格 / 精确 first-last-night-gap），与 `/api/clips` 同过滤；懒加载只决定画多少张卡，不决定头写什么数 | 用已渲染卡片统计当日条数/类型/节奏（一页 30 张会把 4103 条的日子写成「共 30 条」）；为统计去整日加载卡片 |
| 按**捕获日**分片：每天一块 `.masonry.day-masonry` 独立装箱；`relayoutDays` 增量只重排当天；header 出当日条数 + 类型统计 + 288 格五分钟节奏条（活跃跨度 / 峰值半小时 / 夜间占比 / 最长空档）；`#dayRail` 跳日 | 整墙当一个 canvas 每次全量测高；按同步到达时间分组或统计；节奏条另起一套色；跳日走 `fetchPage({reset:true})`（滚到顶） |
| 无人看（隐藏，或 `WALL_IDLE_MS` 无 pointer/key/wheel/touch 输入）→ `parkWall` 停画停解码，SSE 与模型照留；回输入 `wakeWall` 一次补画 | 无人看仍跟每个事件重排/解码；把无头页当常驻客户端（`visibilityState`/`hasFocus()` 对无头一直说谎，判据是**真输入**） |
| 745KB 笔记编辑器首屏不加载；打开笔记才拉 `notes-editor.js` | 把编辑器 bundle 塞进 `<head>` 挡墙首屏 |

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

**不变式：** 同一页霜层；源码 \| 预览；保存走 `compose_saved`，禁止 SSE `update` 刷墙。**标题只由标题栏命名**：存储是 `# title\n\nbody`，正文首个 H1 只要不等于标题就是正文，禁止把它搬进标题栏、也禁止把它从正文剥掉（`ComposeNotes.leadingHeading` + `noteSaveResolution`）。

```text
  #notesPanel
    ├─ 左列表     type=note  置顶复用 pinned_at（不进墙 pin rail）
    └─ 右纸面
         ├─ 打开 → 预览     新建 → 分栏（源码左 / 预览右）
         ├─ CodeMirror 6  |  marked 块 hash LRU + React 18 keyed
         ├─ 关联：#notesLink + 相关 chip；popover 复用 #linkToast
         └─ 弹簧揭纸  clip-path inset（数字插值，禁止 tween 字符串）
              结束必须 clearSheetInline

  多机同一篇
    本机保存才 parentHash + 行级 diff3（ComposeMerge）
    对端 sync compose 按 wallTs **整篇覆盖**，禁止 replica 上 threeWay/both
    空闲机回放自动保存不是双写分叉
    分叉重叠段 <<<<<<< hash 只出现在本机多页保存
    禁止嵌套 <<<<<<<；≥3 个起算爆炸，启动 flatten
```

工具条向源码插 Markdown，不改预览 DOM。**预览藏工具条**（只留模式切换）。删除线钮面是字母 **S** 加删除线（GFM `~~`，`Mod-Shift-x`），不靠 Material ligature、不用汉字。禁止预览露出标记钮。预览纸面宽 = 父 `.notes-preview` 的 **0.618**；代码块头栏「换行」+「复制」，**默认不换行**。禁止把预览卡死在 `38rem`；禁止默认 `pre-wrap`。换行必须 **token-atomic**，四条面共用一个真源 `web/assets/notes-wrap.mjs`：预览代码块 + 预览正文/行内代码 + 源码分栏（CodeMirror `.cm-atomic` mark，只看 `visibleRanges`）+ 墙卡片正文（`.md-preview` / `.notes-rich-inner`，`index.html` 懒加载同一模块）。一**个空白串里的「非 CJK 段」**带内部断点时才套 `.notes-tok`（`inline-block; max-width:100%`），超长段才兜底断。Chrome 实测只在 `- ? – — …` 后、`（` 前断（ASCII `/ : . , _ =` 不断）；CJK 按字断是正常排印，**必须留在 guard 外面**（`笔记分栏编辑界面，--ip` 只守 `--ip`，否则窄栏下 guard 被 `max-width` 夹紧、兜底断就落在 `-` 上）。禁止 `overflow-wrap:anywhere` / `word-break:break-word`，禁止靠 CSS 猜 token（`keep-all` 挡不住拉丁连字符）；禁止把 CJK 包进 guard。墙的 `pre` / `.is-mono` 是 pan 面，不得套 guard。

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
  节拍  GET /api/events?view=beats     用户 / 助手 Stop / Ask 全文
  索引  GET /api/events?view=tools     工具 stub 全量（无正文；禁止 LIMIT 200 砍尾）
  正文  GET /api/event?id=             bundle 展开 / 打开的最后一跳才拉
  hook  SSE stub → GET /api/event?id=  追加；列表 1s 合并
  线程  event_id keyed patch；bundle 就地手风琴
  置顶  DuckDB session_pins + POST /api/sessions/pin   不进墙 pin rail
```

采集是 **Mac 一份 DuckDB + 多机 Quack 写入**，不是 clip 的 trx 同步。远端只装 hook/spool/quack client，禁止每机再起 `server.py`。部署：`docs/trae-hooks.md`。

**hook 禁止每次拉 `/api/sessions`+全量 events。** 工具 **索引必须完整**；bundle 正文 **lazy** 加载。历史回合不得只剩 `Stop.last_assistant_message`。回归：`tests/session-thread.test.mjs`。

列语义色：蜂蜜暖度=`fresh/today/week/old`；工具蓝=`xs/s/m/l`。禁止彩虹。默认打开 `last_ts` 最大的会话。用户气泡全展开；工具只在助手侧压缩，最后一条操作始终展开。

列卡必须标最后一条 `localDateTime`（`YYYY-MM-DD HH:mm:ss`）、实例 `instance_id`、agent 来源 `source`（`trae`/`pi`/`grok`/`codex`，来源色点 + 标签）、工作目录 `cwd`。禁止只用「刚刚」当会话时刻。

**会话是资产。** 只拉正文没有价值，分析必须是**可归因的损耗账本 + Agent 可复测的闭环**（契约：`docs/session-analysis.md`）。分析走 `GET /api/mine`（当前会话 / 最近 7 天；方向可多选：工作目录、Git 库、Taste、任务描述、用户提醒、操作流程、文件、工具、失败/重试、热点/冗余、MCP、阶段、成本/缓存/上下文），四层输出：L0 账本（回合/工具/文件/阶段/成本，事实）→ L1 归因（失败重试、重复读、空等轮询、前缀重填、返工往返、缺定位搜索、空档、skill 上下文成本；秒数**互斥**，按优先级 fail > retry > reread > locate 归账，账本可相加）→ L2 结论（每条必带 impact(秒/$) + cause + action + gate + metric(now/target) + 证据 `refs`(回合/事件 id)，按 $/秒 排序）→ L3 闭环（`format=agent` 返回 `brief` + 稳定 `metric.id` + `verify.rerun`，对**上一个同长度窗口**出 Δ）。**禁止关键词→断言**（「反复提醒 ×N」「prompt 缺路径」这类必须删）：一条结论删掉标题后读者无法自己算出亏了多少，就不该存在。**也要挖用户输入**：提醒/纠正主题要变成 AGENTS 闸门，而不是每次口头重申；操作流程算**额外往返**（短催 + 纠正 + 催促），长任务要求「阶段结论再停」。Agent 侧入口：`python3 trae_hooks/mine.py --agent [--scope session --session-id <id>]`（读 `brief` 后改行为，下次同窗口重跑看 metric 是否向 target 移动）；Agent 可用 `POST /api/mine/ack` 声明「已应用/忽略」（finding_id + status + metric），下一窗口分析回读 `loop` 与 `## 闭环核对`（`fail_n 9 -> 11（目标 0）=> 未改善`），无 target 不判闭环。打开后随 SSE `hook_event` 去抖重算（禁止 `setInterval`）。右下角「分析」在「调试」上方，打开后是铺满会话区的 sheet，禁止 420px 浮层截断路径；`?mine=1` 深链直接打开分析。**sheet 打开时给父页 `clipvault-sessions-overlay`，父页加 `is-overlay` 隐藏面板关闭钮**，避免会话关闭钮与面板关闭钮重合。禁止把分析做成 metrics 再版，禁止把 tool 正文灌进分析 JSON。回归：`tests/session-mine.test.mjs` + `tests/session_mine_main.py`。

禁止：`setInterval` 刷 DOM；每次 hook 整页 `innerHTML`；overlay 盖住后续气泡；embed 窄宽叠成 30vh；用最新 200 条工具当整段历史。

**分析 sheet 不是直播墙。** 自动刷新（SSE `hook_event` 去抖，最少 5s 一次）必须保留用户的**展开态 + 滚动位**；用户点开某回合明细时暂停重绘，只标 stale（`is-pending`），关掉后再刷。内容未变（signature 相同）不得重绘。基线（Δ）只在非自动刷新时请求（查询翻倍）。sheet 铺满线程时，**线程 hook 排队不 patch**（关 sheet 再 flush；积压 >400 走 resync），且覆盖层**禁止 `backdrop-filter`**（blur 会在每次 hook 背后重算 = 肉眼可见的重绘）。回归：`tests/session-mine.test.mjs`。

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

抽取：Readability 前把孤儿 `img`+`figcaption` 包进 `<figure>`；保留「每条 li 有文案+图」。X Article atomic：`MEDIA`/`IMAGE` → 图；`MARKDOWN` → 代码；`DIVIDER` → `<hr>`；`LINK` → `<a>`；其余 `.cv-x-dropped`。inline LINK / `data.urls` / mention 也画 `<a>`（仅 http(s)）。有 `article.title` 时正文 `header-*` 下移一级。`entityMap` 按 `key` 查，禁止当下标。禁止只凭 `cv-x-article` 当成功。X **长帖/Note** 不是 Article：vxtwitter 全文按空行切 `<p>`/`<h2>`，禁止 Readability 单 `<span>` 一坨字。渲染手册：`docs/archive-render.md`。

选区条：28px 浅玻璃；黄点=划线；已有划线弹出「评论 | 删除」；**删除不进评论卡**。

代码：`ArchiveBlobClosure.swift` · `enqueueArchive` / `repairArchiveClosures` / `hydrateBlob`。nmem `clipvault_archive_closure_sync_20260817`。

---

## 同步

```text
  本机事件
    → CloudDocsSyncService.recordLocal*
    → outbox → trx/{host}/{seq}.json
    → blob_keys 点名的对象 → live/attach/{key}.bin
    → iCloud Drive 运输
    → 对端 pull apply（grow-only 字段：ocr_text 更长才写）

  blob_keys = 64 hex  |  {sha}.rtf  |  {sha}.pdf
  本地文件   blobs/{key}.bin     （RTF 是 {sha}.rtf.bin，不是 {sha}.bin）
  readBlobFile 必须认 typed key；count==64 硬拒会把 pull 卡在一条 upsert
  后面的 compose trx 永远不 apply → 笔记看起来不同步
```

```text
  捕获          timestamp = 复制时刻     first_seen_at = 本机首次见到
  OCR 回放      只写 ocr_text            trx.wall_ts = 原 timestamp（禁止 Date()）
  副本 upsert   只补字段                 禁止 MAX(timestamp)
  kind=touch    对端又复制了同一内容      才允许 bump timestamp
  墙            ORDER BY timestamp DESC, id DESC
```

策略真源：`WallClockPolicy.swift`。回归：`tests/wall_clock_main.swift`（策略 + 440 团块 keyset 必须翻到更早 text；类型 chip 走同一 keyset，禁止只滤第 1 页）。

禁止：共享 CAS 当协议；备份切片当同步总线；OCR 只写本机 SQLite；OCR/hydrate 拨捕获钟；把 440 张图合成一张卡；`readBlobFile` 用 `count == 64` 丢掉 `{sha}.rtf`/`{sha}.pdf`。

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

禁止：热 copy 开着的 db；双机写同一 `latest/`；把 bulk full 当默认。自检：`rg -n 'forceFullCopy:\s*true' Sources/ClipVault/` 应无匹配（或仅拒绝分支）。

墙图 `/api/image?id=` 与归档资产同一套回源：`hydrateBlob`（live/attach ∪ backup CAS）。禁止 SQLite 有 type=image 却对墙 404。`blobs/` 禁止指到 `Documents/` 的 symlink（LaunchAgent TCC 读不到历史 CAS；列目录失败不得报 `blobs=0` 成功）。

事故：`docs/incident-20260813` 叙事已迁出；nmem `clipvault_fix_gdrive_edeadlk_cvbak_20260813`。

---

## 操作日志（审计）

**不变式：** `operation_logs` 只追加；`dur_ms` 是**实测墙钟**，NULL = 没计时（不是 0）。抽屉是**读数**，明细是下钻。

```text
  appendOperationLog(action, item, hash, detail, source, durMs: nil?)
        |
        v
  operation_logs (id, ts, action, item_id, content_hash, detail, source, dur_ms)
        |  只追加；不 UPDATE；不写正文
        +-- GET /api/oplogs        过滤明细 (action/source/window/limit)   点开才拉
        +-- GET /api/oplogs/stats  窗口聚合 -> OpsAnalytics (一次查询)
                                      |
              +-----------------------+---------------------+----------------+
              v                       v                     v                v
          类型排行                频次 / 空档           耗时 p50/p95/max   时间序列 (civil 桶)
              +-----------------------+---------------------+----------------+
                                      v
                     预算化信号 firehose / repeat / burst / silent / slow / gap
                                      v
              信号 -> 时间序列 -> 类型排行 -> 耗时 p95 -> 来源构成 -> 明细
```

- 一次一个卡片是普查，不是读数：10831 张 `compose_edit` 卡和 11 张 `reader.comment` 卡长得一样，不滚到底看不出问题。默认只读聚合，明细按 `action` 在 SQL 里过滤。
- 图表按数据形状选（`chartPlan`）：< 3 个桶不画趋势；窗口没有 `dur_ms` 就写「没有任何耗时采样」，不画空轴。
- 预算写在 `OpsAnalytics.Budget`（同 Metrics：没有预算的信号不算信号），信号必带 `now -> target` 与单位。
- 桶是 **civil 桶**（`ClipTimeFormat.displayTimeZone`，DST 正确），与明细 `timeLocal` 同一时区；空桶必须 materialize 成 0（沉默是事实，也是尖峰的基线）。
- 打开抽屉才 `import` 图表模块并取数；每窗口一次聚合请求，30s 内复用缓存，明细不在刷新时拉。

禁止：把 `dur_ms` NULL 当 0ms；用前端已渲染的行统计总数/耗时（一律用 `/api/oplogs/stats`）；未打开抽屉就 import 图表或取数；把 `oplog_no_duration` 这类边界信号静默丢掉。

去哪改：`Store/OpsAnalytics.swift`（聚合 + 预算）· `DatabaseManager.fetchOpLogRows` / `fetchOperationLogs`（SQL）· `web/assets/oplog-panel.mjs`（读数 + 下钻）· `web/assets/mine-charts.mjs` / `.css`（图表皮肤）。回归：`tests/oplog_analytics_main.swift` + `tests/oplog-panel.test.mjs`。

---

## Metrics

本机 `ui-metrics.db`（**不同步、不含正文**）是 UI 优化输入。

```text
  感觉抖 / 白屏 / 慢
       │
       v
  笔记/会话右下角透明「调试」（边框；慢=红 开=蓝）→ 悬浮卡片（再点关闭；随子页生灭）
  GET /api/ui-metrics/recent?name=&limit=40
  GET /api/ui-metrics/summary
  墙：#debug  Cmd-Shift-M
       │
       ├─ 能归因 (name+phase+kind+reason) → 改产品 → 同一 name 对照
       └─ 不能归因                       → 先补点，再改
  #debug 抽屉：结论条(超预算/较基线慢) + 热表 路径·n·avg·p95·max·Δ基线·预算
             + 数据源(本页环缓冲 / 服务器 recent) + trace + 复制诊断
  浮层卡只留越阈值 attention + 关键 name 的 n/avg/max + 最近 payload
```

**指标 UI 三要素：** 单位（ms/cls/count/px）、预算（什么算好）、对照（基线/趋势）。排序与判红一律用 **p95**，不用 max（离群噪声）。Δ基线只在超预算或绝对变化够大（≥20ms / ≥0.02 CLS）时提示，避免亚预算微抖报警。

**p95 只有一个定义：nearest-rank，`rank = ceil(p * n)`（服务端 SQL 整数形式 `(n * p + 99) / 100`）。** 调试读本页环缓冲、备份读服务端 summary，两边必须同定义；2026-10-15 修的就是「前端插值 vs 服务端 `CAST(cnt*p)`」两个口径：2 个样本时服务端把**最小值**当 p95、3 个样本时把最小值当 p50，而排序/判红全用 p95 —— 低报的 p95 正好藏住回归。数值一律经 `fmtVal` 按量级缩放并带单位（禁止裸 `3954105ms` / `p95v 4827425.000`）。

**耗时与"停留时长"分家：** `dur_ms` 是延迟（`wall_fetch`、`sheet_morph`…）；`notes_close.value`、`wall_lifecycle.dur_ms` 是**开着/停画了多久**（session 长度），必须 `budget: null` 声明并给可读标签，禁止当延迟报，也禁止静默 dash。计数类（`notes_open`、`note_switch`）同理：声明显式 null + `unit: 'count'`。

**没有预算的 name 等于没有指标（硬约束）。** 2026-10-14 的 socket 抖动（~1/min）和「墙不刷新」能活到 owner 报障，就是因为 `sse_state` 的 `budget: null` + `metricMeta` 对未声明 name 静默 fallback：**永不判红的指标不是指标**。规则：

1. 新 name 必须进 `web/index.html` 的 `METRIC_SPEC` 并写 `budget`（上下文类显式 `null` 才允许）。
2. 未声明 name 由 `metricMeta` 标 `nobudget: true`，`#debug` 热表显 `无预算`、结论条点名（禁止静默 dash）。
3. **用户可见回归必须有 name**：模型/服务端漂移 `wall_head_drift`、socket 抖动 `sse_socket_churn`（服务端 5min 开数）+ 换主 `sse_churn`、捕获静默丢弃 `capture_gap`、布局漂移 `wall_layout_drift`。
4. 归因必须有一等指标：客户端正常断开写 `sse_state phase=close reason=client_gone`，驱逐写 `reason=overflow`；**禁止**用一个含糊的 `reason=peer` 笼统覆盖两种事实。
5. 换主/socket 抖动这类「交互型」回归用**可执行台架**复现（`tests/helpers/sse-election.mjs` 虚拟时钟 + 假 BroadcastChannel），不靠真浏览器人工观察。

门禁：`tests/metrics-panel.test.mjs`（spec 与 `nobudget` 语义）、`tests/sse-election.test.mjs`、`tests/wall-live-update.test.mjs`。

**字段语义（禁止混用）：** `dur_ms`=延迟；`value`=量（CLS 值、held ms、bytes、lag…）；`ok`=成功/失败；`over`=是否超预算；`trace`=一次加载/面板开合的关联 id。`summary` 另出 p50/p95/p99、`ok_rate`，并按 route/status 拆 `http_req`。**明细保留 7 天**，更早的折成 `ui_rollup`（小时聚合，保留 30 天，无精确分位）；prune 走 `incremental_vacuum`。p50/p95/p99 只在明细窗口内精确。

| 症状 | name |
| --- | --- |
| 墙刷新 | `wall_fetch` `wall_merge` `wall_paint` `wall_resync` `wall_dayindex`（日统计聚合，budget 120ms） |
| 墙停画生命周期 | `wall_lifecycle` phase=park/wake + reason（hidden/idle/input/visible）；`wall_merge` kind=burst phase=coalesce n |
| 时间线跳日 | `wall_day_jump` payload day/days（count） |
| 墙插入 CLS | `wall_cls` kind=m3-card phase=wall；`wall_paint` kind=prepend phase=keep\|top |
| 墙长任务 | `wall_longtask` phase=loaf\|longtask + kind/reason/host |
| 开合 sheet | `sheet_morph` `sheet_cls` `notes_cls` `trae_sessions_cls` |
| 开合笔记顶栏跳 | `chrome_shift` phase=open\|close dy/reason；长周期 `wall_cls` |
| 墙加载/补体 | `wall_load`（首屏 span）；`wall_hydrate`（?ids= 批量补体 n/bytes） |
| SSE 生命周期 | `sse_state` phase=open/error/reconnect/role/watch/**close**(reason=client_gone|overflow|send_failed) + reason；`sse_wall` 只留逐条吞吐 |
| SSE socket 抖动 | `sse_socket_churn`（5min 内开数，budget 3）+ 前端 `sse_churn`（<60s 内再次换主=over）；`wall_head_drift`（合入后仍与服务端头部不一致=over，budget 0） |
| 捕获静默丢弃 | `capture_gap`（归档窗口内被吸收的贴板变更数，budget 0） |
| 笔记输入卡 | `notes_longtask` `notes_inp` `notes_preview_ms` |
| 笔记 Markdown | `notes_md_compile` vs `notes_preview_ms`；payload `compiled`/`reused`/`n`/`ratio` |
| 会话白屏 | `trae_sessions_skip` vs `trae_sessions_paint` `trae_sessions_layout` |
| 会话 Markdown | `trae_sessions_md`（paint 内 md 块耗时合计） |
| 资源泄漏 / 502 | `proc_sample`（fds/rss/unix/sse/rlim）；SSE `ping` 同字段；`GET /api/ui-metrics/proc` |
| HTTP 边车 | `http_req` dur=总时间；`lag`=origin；`n`=status；`route` 去 query/id；`proto` h1/h2；`phase` ok/stream/origin_* |
| 交互行为 | `ui_interact` payload `zone`/`action`/`target`/`via`（点击/切换/输入/快捷键/hover 划读）；`target` 是 DOM 句柄，禁止元素文本 |

**交互打点是 UI 优化输入。** `web/assets/ui-track.js` 用委托监听把 click/change/keydown 归一成 `ui_interact`；`target` 取 `data-ui` → `id` → 动作属性（`data-pin`/`data-del`…）→ class → tag，`action` 由动作属性映射成动词，`zone` 由最近的 `[data-ui-zone]` 决定。禁止把元素文本/输入值/搜索词写进 payload；禁止每页各自 new 一套点击监听。

`notes_close.value` = 开着多久（墙钟，不是延迟）；关动画看 `notes_close_anim` 或 `sheet_morph` phase=close。CLS 一律用 `value`（`wall_cls`/`notes_cls`/`sheet_cls`）。Agent 自己拉 metrics。笔记/会话入口是右下角「调试」悬浮卡，只看关键 name。

备份徽章走 SSE `backup_status` + `?lite=1`，禁止 30s 轮询 `/api/backup/status`。

---

## HTTP / SSE 控制面

```text
  EventSource /api/events
    retry: 3000
    15s  : ping  + {"type":"ping"}
    每连接队列 32；满 → coalesce resync_required（禁止静默踢）
    onopen / visibility / focus / pageshow / online → scheduleResync → mergeHead
                                   必须同时 mergeNotesHead
    活 GET /api/clips 禁止浏览器缓存（no-store）；后台冻住 SSE 后回前台靠 mergeHead
    后台：单页保持 EventSource。仅当 BroadcastChannel 里已有其它 leader
    才放掉 socket（81244ea 多 tab 省连接）。禁止 hidden 一律 teardown。

  禁止 onerror 里 close()+setTimeout 当唯一重连
  HTTP/2 下 EventSource 占一条 stream
  origin SSE = CV01 stream；drop 必须 close unix fd
  clipvault-http 在 body drop 时关掉 origin fd（禁止泄漏 UDS）
  needs_user：TraeAskFanIn 并进墙 SSE，禁止每页再挂 /trae/api/stream
```

---

## 隐私

默认数据在用户目录；备份在用户自己的云盘。剪贴板当敏感数据：日志脱敏；密钥/token **永不**进 nmem / chat / commit。

---

## Android

路径 `android/`。备份阅读器 + 前台粘贴/分享；**不做**后台剪贴板监听。SAF 优先 `ClipVault/cvbak`。发布 `.github/workflows/android-apk.yml`。详情 WebView：JS 关；与墙同一策略——不信任 `style`、不渲染可点 `<a>`、不拉远程 `<img>`、删 `on*`/SVG/表单。

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
./scripts/verify-single-instance.sh  # server=1 · front=1 · lock owner==server pid
# 明文自检：curl --noproxy '*' --http2-prior-knowledge http://127.0.0.1/api/clips?limit=1
```

### 前端门禁

改 `web/index.html` 后、push / 部署前：

```bash
./scripts/check-frontend.sh
```

门禁是 `scripts/check-frontend.sh`：`node --test tests/*.test.mjs`，文件名**硬编码**在脚本 gates 注释里。新测试必须追加进该注释。墙记忆丢失：`tests/wall-integrity.test.mjs` + `tests/wall_clock_main.swift` + `tests/wall-clock.test.mjs`。**内联脚本必须在 jsdom 里能启动到底**：`tests/wall-boot.test.mjs`（顶层 TDZ 会把整段脚本打死但所有源码扫描仍绿）。`node --check` 不过禁止上线。

### commit / push

```text
改完一个单元 → 验证 → git status/diff → commit → push → 再开下一单元
```

粒度：一步一提交；message = subject + 空行 + why。不混装。回复带 HEAD、是否已 push、远程范围。

临时文件（截图、探针、日志、下载的制品、一次性 fixture）**一律写 `.tmp/`**（已 gitignore），
禁止落在仓库根或 `web/`、`Sources/`、`tests/` 等受维护路径。仓库根只留受维护文件。

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
| 墙记忆丢失（拨钟/砍尾/滤错/图404/塌列/折头/不动） | 本文硬约束 4–5；`tests/wall-integrity.test.mjs` + `tests/wall-live-update.test.mjs` |
| GDrive EDEADLK | nmem `clipvault_fix_gdrive_edeadlk_cvbak_20260813` |
| 操作日志读数 | 本文 · 操作日志（审计）；`tests/oplog_analytics_main.swift` + `tests/oplog-panel.test.mjs` |
| URL/HTML 安全 | nmem `clipvault_gate_url_html_safety_20260813` |
| SQLite 运维 | `.trae/skills/sqlite-runtime-tricks/` |
| clip-link | `docs/feature-clip-link.md` |
| 归档功能 | `docs/feature-url-archive.md` |
| 归档渲染 | `docs/archive-render.md` |
| Trae 会话采集 | `docs/trae-hooks.md` |

一句话：**ClipVault = 个人剪贴板记忆。** 终局、像产品、本机优先。历史文件夹名不定义品牌。
