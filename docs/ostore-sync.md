# ostore live sync — 多端实时同步的第二个 wire

Owner 目标：**两台以上 ClipVault 之间，一次复制到对端墙上出现 ≤ 3s**。

iCloud Drive 那条腿（`CloudDocsSyncService` + `CloudDocs` 目录）语义正确但延迟由 File Provider
决定（45s 轮询、dataless 下载）。ostore 是同一份 per-host trx 日志的第二条 wire：HTTP 对象的
`PUT`/`GET` 负责搬运，对象事件流（SSE）负责"对端刚发了"这一声通知。

```text
   本机复制                                           对端
   ────────                                          ────
   enqueue → sync/outbox/{seq}.json
        │  coalesce 150ms
        v
   POST /api/batch  {trx + attach}  ──────────►  ostore  clipvault/sync/v1/
        │                                        │      trx/{host}/{seq}.json
        │                                        │      attach/{key}.bin
        │                                        │      heads/{host}.json
        │                                        │
        │                             object.created 事件（prefix 过滤）
        │                                        │
        │                                        v
        └────── SSE /api/events?prefix=…  ──►  peer 收到事件
                                                   │  coalesce 150ms
                                                   v
                                          一次 list + GET trx/attach
                                                   │
                                                   v
                                          apply → ClipVaultItemAdded
                                                   │
                                                   v
                                          墙 SSE data: new_item（浏览器 < 1s）
```

## 契约（与 iCloud wire 完全一致）

| 项 | 值 |
| --- | --- |
| 事务格式 | `SyncOp`（`CloudDocsSyncService.SyncOp`），两条 wire 同一份 JSON |
| 序号 | 每 host 单调 `seq`，`trx/{host}/{016d}.json` |
| 游标 | `keepsake_meta.sync.applied.{host}` —— **按 host 而非按 wire** |
| 附件 | `attach/{key}.bin`，key 就是 `blob_keys` 里的键（含 `.rtf`/`.pdf` 后缀） |
| 合并规则 | `applyOpLocked` / `applyIsIdempotentSuccess`，与 iCloud 共用一份 |
| 顺序 | 附件必须先于同名 trx 可见；对端只因 trx 事件动作 |
| 备份 | **不是**同步总线。`OstoreBackup` 的 `clipvault/backup/**` 与 `sync/` 互不相干 |

游标按 host 意味着 `clouddocs` / `ostore` / `both` 可以混部：一条 wire 上拿到的 op 推进同
一个游标，另一条 wire 不会重复 apply。

## Wire 选择

`config/sync.json`：

```json
{ "transport": "both", "ostorePrefix": "clipvault/sync/v1" }
```

| `transport` | 行为 |
| --- | --- |
| `clouddocs` | 旧行为：只走 iCloud（默认值，老安装不改配置） |
| `ostore` | 只走 ostore：SSE 事件驱动，事件流断了回落到 2s 轮询 |
| `both` | 两边都发，两边都拉。iCloud 在事件驱动的 cycle 里限速 5s 一次 |

运行期可切换：`POST /api/sync/config {"transport":"ostore"}`（也接受 `ostorePrefix`，可与
`enabled` 同时给）。`GET /api/sync/status` 新增 `transport` / `ostorePrefix` /
`ostoreBaseHost` / `ostoreConnected` / `ostoreLastEventUnix`。

## 凭据

与冷备同一份文件，**0600**，不进仓库、不进日志、不进 nmem：

```json
// $CLIPVAULT_HOME/config/ostore-backup.json
{ "baseURL": "https://…/clipvault-ostore", "token": "<OSTORE_TOKEN>", "enabled": false }
```

`enabled` 只控制冷备镜像，**不控制 transport**：暂停冷备不应该让同步静默停摆。
没有这个文件（或不是 https）→ `ostoreWire` 为 nil，cycle 里 `push:ostore no_config`，不影响
`clouddocs` 腿。

## 时延预算（实测口径）

| 段 | 典型 | 说明 |
| --- | --- | --- |
| 复制 → 入 outbox | < 20ms | `recordLocalCapture` → `enqueue` |
| coalesce | 150ms | 突发多次复制合并成一次 cycle |
| 发布 | 0.3–0.8s | 一次 `POST /api/batch`（trx + ≤6MiB 附件）；大附件单独 PUT |
| 事件 → 对端 | 50–150ms | ostore SSE，`prefix` 过滤后几乎零噪声 |
| 对端拉取 | 0.3–0.8s | 一次 `list` 拿到索引 + 一次 GET trx（+ 附件） |
| apply → 墙 SSE | < 50ms | `ClipVaultItemAdded` → `/api/events` |

事件流断了：2s 轮询兜底（`ostoreOfflinePollSeconds`），端到端仍在 3s 量级；事件流在时轮询
30s，只做兜底对账。

## 观测

`ui-metrics.db`（本机，不含正文）：

| name | 含义 |
| --- | --- |
| `sync_push` (`wire=ostore`) | 一轮发布耗时 + 发布条数 |
| `sync_pull` (`wire=ostore`) | 一轮拉取耗时 + apply 条数 |
| `sync_apply` (`wire=ostore`) | 按 kind 的 apply 成功/失败 |
| `sync_blob_wait` | 附件晚于 trx 到达（会触发 0.6s 追补 drain） |
| `sync_cycle` | 整轮（两条 wire 合计） |
| `sync_queue_depth` / `sync_peer_lag` | outbox 积压 / 最差对端滞后 |

`GET /api/sync/status` 里 `ostoreConnected=false` 时，说明现在是轮询在扛，先查
`lastError` 与 `lastPhase`。

## 排查顺序

```text
对端不动
  ├─ 本机 /api/sync/status：outboxPending 是否 >0？lastError？
  ├─ ostore：GET {prefix}/trx/{本机 host}/ 最新 seq 是不是刚才那条
  │    └─ 不是 → 发布没成功（token / baseURL / batch 契约）
  ├─ ostoreConnected？false → SSE 断了（Caddy/Cloudflare 缓冲、token、prefix）
  ├─ 对端 appliedSeq 是否停在 seq-1
  │    ├─ 停住且 phase=blob_wait → attach 缺失（先发 trx 后发附件 = bug）
  │    └─ 停住且 phase=retry <kind> → apply 拒绝（看 kind 的不变式）
  └─ 墙不刷新：`/api/events` 是否连上（浏览器 18s stale 是隧道问题，不是同步）
```

## 禁止

- **禁止**把 `clipvault/backup/**`（冷备切片）当同步总线，或反过来让同步写备份目录。
- **禁止**新增第三条"给我也发一份"的私有日志；同步只有 `trx/` 一份真源。
- **禁止**在对端"先看到 trx 再传附件"的顺序上做优化（对端只因 trx 事件动作）。
- **禁止**用 `sha256` 字段做对象校验：cc ostore 的 `list.sha256` 历史上装的是 MD5，认 `md5`。
- **禁止**在 ostore 事件里做业务判断；事件只触发一次 cycle，真相永远来自 `list` + 游标。
- **禁止**把 token 写进日志、指标、commit 或 nmem。

## 验收（本机可复现）

```bash
# 1) 发布：复制一段文本，3s 内 ostore 出现本机 host 的新 trx
TOKEN=$(ssh cc 'grep ^OSTORE_TOKEN /etc/ostore.env | cut -d= -f2-')
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://<base>/clipvault-ostore/api/list?path=clipvault/sync/v1/trx/$(host)-…&recursive=1" | jq '.total_count'

# 2) 拉取：往对端 host 的 trx 里塞一条 upsert，3s 内 /api/list 出现该 item，且 /api/events 推了 new_item
# 3) 断流：kill 掉 SSE（改错 prefix 重启），确认 2s 轮询仍能在 3s 内补齐
```
