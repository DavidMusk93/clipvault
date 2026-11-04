# ostore 冷备

ClipVault 在本机备份成功后，把该主机的数据库和 CAS 媒体增量复制到 ostore。备份不参与多机同步。每台机器使用独立的 `hostId`。

## 配置

在 ClipVault 数据目录的 `config/ostore-backup.json` 写入以下格式，权限设为 `0600`。密钥只放服务端，禁止提交或下发到浏览器。

```json
{"baseURL":"https://cc.guohuasun.com/clipvault-ostore","token":"<OSTORE_TOKEN>","enabled":true}
```

`enabled` 缺省为 `true`（旧配置无需改动）。它是面板上 ostore 行的开关，写入的是同一个 `0600` 文件，只改这一个键、保留 `baseURL` / `token` 与其它未知键。cc 上现在只有一个 ostore，监听 `127.0.0.1:8781`，根目录 `/srv/ostore`。Caddy 仍把 `/clipvault-ostore/` 剥前缀后反代到这个实例。令牌用这一实例的 `OSTORE_TOKEN`，不再使用已删除的 `ostore-clipvault.service`。对象仍写在 `clipvault/` 前缀下，和网盘其它目录隔开。集群复制不包含 `clipvault/`。

## 面板形态（统一，不是特例）

```text
备份源
  iCloud Drive    [可用]   <路径>            上次/phase      (开关)
  Google Drive    [可用]   <路径>            上次/phase      (开关)
  夸克网盘         [云端可见] <路径> + hint     上次/phase      (开关)
  ostore 远程冷备  [可用]   <baseURL>        上次/phase      (开关)
      └ #bkOstoreStats：本轮/远端/上次运行统计（见下）
```

四行同一套结构：`pill` + 路径行 + `上次/phase` 行 + 右侧 `.switch`；`ostore` 不是特例，没有单独的「备份到 ostore」按钮。

| 交互 | 契约 |
| --- | --- |
| 开关 | `POST /api/backup/config {"ostoreEnabled":bool}` → 写 `enabled`（`0600`，保留其它键）；`enabled=false` 后 fan-out 不再 enqueue |
| 手动触发 | 面板「立即备份」（`POST /api/backup/run`）统一触发本机备份 + 各备份源；`POST /api/backup/ostore/run` 仅留给 CLI/agent |
| 未配置 | 开关禁用、pill 显示「未配置」，行内给出 `config/ostore-backup.json` 写法 |
| 上传中 | pill「上传中」，状态行 prose 说明；再触发只排队，不会出现重复上传 |

## 备份历史

「运行记录」把 24 小时或 7 天内的每次运行画在同一条真实时间轴上，分本机、ostore 两行（高 = 耗时，两行各自刻度；红 = 失败；斜纹带 = ostore 正在上传）。划过即读，点击或 ←→ 钉住一次运行看详情。版式见 `docs/design-taste.md` §备份面板。数据来自本机 `ui-metrics.db`：

- `backup_cycle`：既有的手动本机备份历史；新版本继续记录，和新的本机运行记录按手动类型去重。
- `backup_local_run`：新版本起记录实际开始的本机备份（自动、手动、恢复前安全快照）；调度阶段的未执行、节流等不算运行。
- `backup_ostore_run`：新版本起记录每次结束的 ostore 上传，包括成功与失败、耗时、上传/跳过对象数与上传字节数。
- 此前 `ostore-backup.state.json` 只留最近一轮；窗口内会显示这一条真实留存记录，不能还原更早的 ostore 轮次。历史读取每种指标最多返回最近 200 条，达到上限时页面提示可能有遗漏；明细受 metrics 存储的保留期限约束。

## 运行和状态

本机备份成功或内容未变时自动排队；`POST /api/backup/ostore/run` 先运行本机备份，再异步上传。`GET /api/backup/status` 的 `ostore` 就是面板看到的全部统计：

| 字段 | 含义 |
| --- | --- |
| `phase` / `inProgress` / `lastError` | 本轮阶段、是否在上传、错误 |
| `queued` | 上传进行中又被点了一次：已排队，本轮结束后自动开始（不会重复上传） |
| `total` / `uploaded` / `skipped` / `failed` / `pending` | 本轮对象数（blobs + 可选的整库基线 + 可选的逻辑增量 + `latest/DB-CHECKPOINT.json` + `latest/MANIFEST.json`） |
| `uploadedBytes` / `skippedBytes` | 本轮字节数（按实际文件大小） |
| `manifestObjects` / `manifestBytes` | 本轮本地清单声明的对象数与字节数（恢复预期量） |
| `remoteObjects` / `remoteBytes` | 本轮结束时重新列一次远端 host 前缀得到的实际对象数与字节数 |
| `startedUnix` / `durationSeconds` | 本轮起止与耗时 |
| `lastSuccessUnix` | 最近一次成功时间 |
| `lastRun` | 上一轮完整快照（phase/host/计数/字节/耗时/错误） |

```text
live counters ──(每 ≤2s 一次 backup_status ping)──> Web 面板本轮对象/本轮字节/耗时
       \
        └─(run 结束)──> lastRun ──> config/ostore-backup.state.json (0600)
                                            \
                                             └─> 重启后仍显示「上次运行」与远端对象数
```

本轮计数只在进程内累加；`lastRun` 与 `lastSuccessUnix` 落盘到 `config/ostore-backup.state.json`（0600，与凭据同目录），所以重启不会再把统计清零成「上传 0 · 跳过 0」。上传进行中每 2 秒最多广播一次 `backup_status`，避免长时间上传时面板停在陈旧数字。上传进行中再点一次「立即备份」只会把下一轮排到 `pending`（后到的覆盖先到的），状态行显示「已排队下一轮」，不会重复上传。

```text
local sqlite3_backup + VACUUM 整文件          # 云盘仍是整文件，允许 VACUUM
    -> ostore blobs/<name>                    # 按文件 MD5 跳过
    -> ostore databases/<sha256>.db           # 只在还没有基线时上传一次
    -> ostore deltas/<md5>                    # 之后只上传变过的行
    -> ostore latest/DB-CHECKPOINT.json
    -> ostore latest/MANIFEST.json
```

增量不看页号。VACUUM 可以重排整个文件。比较的是行：`clipboard_items` 按整行 MD5，追加表（`compose_ops`、`clipboard_events`、`operation_logs` 等）按时间戳和 id，小表按整表 MD5。没变的行不进增量文件。游标在 `config/ostore-logical.json`（0600）。基线传成功之后才记下游标。

`DB-CHECKPOINT.json` 的 `version` 是 2，带 `baseSha256`、`deltaMd5`、`deltaBytes`、`counts`。

对象是否已在远端，用文件的 MD5 判断，不用 SHA-256。cc 的 ostore 从 2026-11-03 起把 MD5 写进列表的 `sha256` 字段，同时另给 `md5`；PUT 响应里的 `sha256` 仍是真正的 SHA-256，`md5` 才是内容校验。跳过条件是 `md5`（或 32 位的 `sha256`）与本地 MD5 相同。对不上才 PUT，并且只接受响应里的 MD5。`uploaded + skipped` 即本轮通过校验的对象数（面板「本轮对象」）。

本地清单里的 `sha256` 仍是云盘那份 vacuum 后 sqlite 的 SHA-256，用来确认 `latest/clipflow.db` 和清单是同一份。它不参与 ostore 的页块比较。

数据库与清单不匹配、媒体缺失、鉴权或网络错误时报告失败；本机备份不回滚。checkpoint 在全部页块成功之后才上传。媒体和已经上传过的页块都不会自动删除。

## 灾难恢复

在隔离目录下载 `latest/DB-CHECKPOINT.json`。用其中的 `baseSha256` 下载 `databases/<baseSha256>.db` 作为起点。按时间顺序把 `deltas/<deltaMd5>` 里的行 `INSERT OR REPLACE` 进对应表；`clipboard_items_removed` 里的 id 从 `clipboard_items` 删掉。全文索引可以在恢复后重建，增量里没有 FTS。媒体按 `latest/MANIFEST.json` 的 `blobFiles` 下载。检查 `PRAGMA integrity_check`。不要把远端备份当成同步总线，也不要直接覆盖正在使用的数据库。

2026-11-04 中午一度按 64 页切块上传。那种做法要求页布局不变，VACUUM 会让所有块失效。那些 `db-chunks/` 对象可以忽略。
