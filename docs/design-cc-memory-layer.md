# design-cc-memory-layer — ClipVault 笔记/记忆层上 cc（设计稿 v1）

状态：**设计，未实施**。Owner 裁决点见 §9。真源上下文：nmem `da49996f`（cc 事实）、`a2bb4239`（agent API 规划）、`deb7a3bc`（ostore 单实例架构）。

## 一句话结论

在 ssh cc 上新增一个与 `clipvault-session` 同族的 Rust 服务 **`clipvault-notes`**：内嵌 notebase crates 作为笔记引擎，通过**既有 ostore trx wire** 与 mac 侧 ClipVault 双向同步，对 agent 暴露与 `/api/notes*` **同形状**的 API（`cv-notes --base` 直用）—— mac 保持用户主操作员，cc 成为 agent 协同编写与记忆层核心。

## cc 现有事实（2026-11-18 实测）

| 项 | 值 |
| --- | --- |
| 主机 | `ssh cc` = <deployment-host>，Debian 12，cargo 可用，无 swift/docker |
| `ostore.service` | `/root/ostore/target/release/ostore`，`127.0.0.1:8781`，root `/srv/ostore`，env `/etc/ostore.env`（OSTORE_TOKEN），cluster `/etc/ostore-cluster.json` |
| clipvault 前缀 | `/srv/ostore/clipvault/{sync,backup}` —— mac 侧 trx wire 已在写 `sync/` |
| `clipvault-session.service` | Rust `:9488`（SA-v1 facade，replica），存储 PostgreSQL `127.0.0.1:5432/clipvault`，web 资产 `/root/clipvault/web` |
| `caddy.service` | 公网入口（xstream 前后端在用），Caddyfile 历史备份齐全 |
| 仓库镜像 | `/root/recallfs/projects/clipvault`（空壳，待 git pull） |

mac 侧：`CLIPVAULT_NOTEBASE_PRIMARY=1` 已生效（notebase 已是 mac 的笔记引擎）；agent API P0–P4 已全部落地（`/api/notes*`、token、kind 词汇表、`cv-notes`）。

## 目标

1. agent 在任何可达 cc 的环境用同一套 `/api/notes*` 形状读写笔记，不依赖 mac 开机。
2. 复用 ostore（存储 CAS + trx wire + SSE 通知），**不发明第三条同步日志**。
3. mac 用户与 cc agent 共同编辑收敛，用户仍是主操作员（mac 语义零改动）。

## 非目标

- 不在 cc 跑 ClipVaultServer（Swift/AppKit 不可移植）；不做多租户；不迁移用户主库到 cc。
- 不改 mac 侧 `/api/compose`、`#notesPanel`、同步协议（cc 是新 peer，不是新协议）。

## 架构

```text
[用户 mac: ClipVaultServer] ── 用户 UI / 墙 / compose 管线（一字不动）
        │  PUT/POST /api/batch + SSE ?prefix=            （既有 ostore wire）
        v
  /srv/ostore/clipvault/sync/v1/
        trx/{host}/{seq}.json  attach/{key}.bin  heads/{host}.json
        ^                                        ^
        │ apply（note trx: 整篇覆盖 wallTs 语义照旧） │ publish（agent 写入 → 自己的 trx）
        │                                        │
[cc: clipvault-notes (Rust axum, :9490 loopback)]
        ├─ notebase crates 内嵌：notebase(文档) + notebase-store(SQLite oplog/FTS5/snapshots)
        ├─ blobs → ostore CAS（PUT /srv/ostore/clipvault/sync/v1/attach/...）
        ├─ own host id = "cc"（游标 sync.applied.cc、cc 侧 applied.mac-home 独立推进）
        └─ API：/api/notes* 与 mac 同形状（含 token、kind 词汇表、_meta、related）
                  ^
                  │  http://127.0.0.1:9490（Caddy 内网路由，或 ssh -L 隧道）
[agents: cv-notes --base https://cc.../notes-api | pi / grok / trae hooks]
```

要点：

- **notebase 是引擎，不是 FFI 跨界**：cc 服务用 Rust 直接依赖 `notebase`/`notebase-store`/`notebase-sync` crates（mac 是同一套 crate 的 Swift 绑定），文档/投影语义天然一致。
- **note trx 同步语义沿用 mac↔mac**：compose trx 是整篇 body + wallTs；replica 端整篇覆盖。cc↔mac 双向即"两台 mac"的既有规则，分叉重叠段冲突标记与 flatten 已有处理。
- **cc 自己的写也要 publish trx**：agent 在 cc 写入 → notebase oplog + 生成 note trx → ostore → mac pull apply → mac 用户 UI 看到 agent 的编辑（与 mac↔mac 对等）。
- **PG 复用可选**：`clipvault-session` 的 PG 实例可挂投影/审计表（oplog 聚合、agent 使用统计），不是笔记真源。

## API 与鉴权

| 项 | 决定 |
| --- | --- |
| 端口 | `127.0.0.1:9490`，systemd `clipvault-notes.service`（同族模板：EnvironmentFile + 0600 env） |
| 形状 | 与 mac `/api/notes*` 逐端点同形状（_meta 返回 `api:"clipvault-notes", host:"cc"` 便于探测） |
| 鉴权 | Bearer token（`/root/.config/clipvault/notes-token` 0600）；不暴露公网即不引 TOTP；Caddy 若加公网路由，先上 mTLS/内网限制 |
| 客户端 | `cv-notes --base https://... --token ...`（CLI 已支持远程 base） |

## 阶段

| Phase | 交付 | 验证 |
| --- | --- | --- |
| D0 | 本设计文档 + owner 裁决 §9 | 本节 |
| D1 | `clipvault-notes` 骨架：notebase store + `/api/notes/_meta|POST /api/notes|GET list/{id}` + token | curl 活体 |
| D2 | ostore trx 双向：apply mac note trx（含 RTF/PDF typed blob key 教训：readBlobFile 等价物必须认 typed key）+ publish cc trx；mac 部署实测收敛 | mac↔cc 对写收敛 |
| D3 | tags/links/related/related 检索补齐 + oplog/PG 审计投影 + `cv-notes` 全量联测 | 门禁 + 活体 |

## 风险与既有教训的映射

| 风险 | 处置 |
| --- | --- |
| typed blob key（`{sha}.rtf`/`.pdf`）卡 pull（mac 事故 37d9479） | cc apply 侧从一开始就认 typed key；回归用例必带 |
| 双向整篇覆盖放大 agent 高频写 | cc 侧落盘走 notebase delta oplog（天然解决 mac compose_ops 写放大问题）；trx 折叠沿用 per-host 序 |
| ostore `list.sha256` 历史上是 MD5 | 沿用 AGENTS 禁令：不拿它当对象校验 |
| agent 高频写打爆 SSE 通知 | cc 侧 cycle coalesce（mac 已是 150ms），事件只触发 pull |
| token 泄漏 | 0600 文件 + 不进日志/nmem/commit；泄漏即轮换 |

## Owner 裁决点（§9）

1. cc 服务名/端口 `clipvault-notes` :9490 是否认可。
2. agent 入口暴露面：仅 loopback + ssh 隧道（默认），还是 Caddy 公网路由 + 更强鉴权。
3. cc 侧笔记引擎数据落点：`/root/clipvault/notes/`（与 session 同根）是否认可。
4. cc 上的 agent 身份集合（`agent:<name>` 白名单是否需要）。
