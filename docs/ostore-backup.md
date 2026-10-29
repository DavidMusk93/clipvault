# ostore 冷备

ClipVault 在本机备份成功后，把该主机的数据库和 CAS 媒体增量复制到 ostore。备份不参与多机同步。每台机器使用独立的 `hostId`。

## 配置

在 ClipVault 数据目录的 `config/ostore-backup.json` 写入以下格式，权限设为 `0600`。密钥只放服务端，禁止提交或下发到浏览器。

```json
{"baseURL":"https://cc.guohuasun.com/clipvault-ostore","token":"<OSTORE_TOKEN>"}
```

地址必须为 HTTPS。cc 的 `ostore-clipvault.service` 使用独立令牌、根目录 `/srv/ostore-clipvault` 和 loopback 端口 8782；Caddy 将 `/clipvault-ostore/` 反代至该实例。它与 xstream 的 ostore 权限和数据隔离。

## 运行和状态

本机备份成功或内容未变时自动排队；`POST /api/backup/ostore/run` 先运行本机备份，再异步上传。`GET /api/backup/status` 的 `ostore` 就是面板看到的全部统计：

| 字段 | 含义 |
| --- | --- |
| `phase` / `inProgress` / `lastError` | 本轮阶段、是否在上传、错误 |
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

本轮计数只在进程内累加；`lastRun` 与 `lastSuccessUnix` 落盘到 `config/ostore-backup.state.json`（0600，与凭据同目录），所以重启不会再把统计清零成「上传 0 · 跳过 0」。上传进行中每 2 秒最多广播一次 `backup_status`，避免长时间上传时面板停在陈旧数字。

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
