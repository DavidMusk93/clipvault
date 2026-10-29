# ostore 冷备

ClipVault 在本机备份成功后，把该主机的数据库和 CAS 媒体增量复制到 ostore。备份不参与多机同步。每台机器使用独立的 `hostId`。

## 配置

在 ClipVault 数据目录的 `config/ostore-backup.json` 写入以下格式，权限设为 `0600`。密钥只放服务端，禁止提交或下发到浏览器。

```json
{"baseURL":"https://cc.guohuasun.com/clipvault-ostore","token":"<OSTORE_TOKEN>","enabled":true}
```

`enabled` 缺省为 `true`（旧配置无需改动）。它是面板上 ostore 行的开关，写入的是同一个 `0600` 文件，只改这一个键、保留 `baseURL` / `token` 与其它未知键。cc 的 `ostore-clipvault.service` 使用独立令牌、根目录 `/srv/ostore-clipvault` 和 loopback 端口 8782；Caddy 将 `/clipvault-ostore/` 反代至该实例。它与 xstream 的 ostore 权限和数据隔离。

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

面板按 24 小时或 7 天展示每次运行耗时；可按本机、ostore 或全部筛选，点击柱子查看时间、结果和耗时。数据来自本机 `ui-metrics.db`：

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
| `total` / `uploaded` / `skipped` / `failed` / `pending` | 本轮对象数（blobs + `databases/SHA.db` + `latest/clipflow.db` + `latest/MANIFEST.json`）与其中已传、已跳过、失败、未完成 |
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
local sqlite3_backup + verified CAS
    -> hosts/H/latest + hosts/H/blobs
    -> ostore clipvault/backup/hosts/H/blobs
    -> ostore clipvault/backup/hosts/H/databases/SHA.db
    -> ostore clipvault/backup/hosts/H/latest/{clipflow.db,MANIFEST.json}
```

逐文件 SHA-256 对账，已有对象跳过，上传响应的 SHA-256 必须匹配；`uploaded + skipped` 即本轮通过哈希校验的对象数（面板「本轮对象」）。数据库与清单不匹配、媒体缺失、鉴权或网络错误时报告失败；本机备份不回滚。最新清单最后上传，但两个 latest 文件不是原子事务；上传中断时 `latest/clipflow.db` 可能与清单不一致，恢复时必须校验。数据库内容寻址副本保留当前和上一个版本；媒体不会自动删除。

## 灾难恢复

在隔离目录下载对应 host 的 `latest/MANIFEST.json`，使用其 `sha256` 下载 `databases/<sha256>.db`，按 `blobFiles` 下载 `blobs/`，逐个校验文件完整性。清单中 `sha256` 是数据库 SHA-256；若使用 `latest/clipflow.db`，必须先与此值比较。检查 SQLite `PRAGMA integrity_check` 后，再按现有 ClipVault 恢复流程操作。不要把远端备份当成同步总线，也不要直接覆盖正在使用的数据库。
