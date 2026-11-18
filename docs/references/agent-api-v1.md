---
doc_id: clipvault-agent-api-notes-v1
kind: reference
status: active
authority: design
applies_to:
  - Sources/ClipVault/HTTP/WebServer.swift
  - Sources/ClipVault/HTTP/AgentNotesAccess.swift
  - Sources/ClipVault/Store/NoteTags.swift
  - cc-notes/src/main.rs
  - cc-notes/src/links.rs
  - scripts/cv-notes
depends_on:
  - AGENTS.md
supersedes: []
verified_by:
  - scripts/check-frontend.sh
  - scripts/check-doc-guard.sh
---

# Agent API · ClipVault 笔记 v1

给编码 agent 的使用契约。**v1 在路径里**（`/api/v1/notes*`），未来 v2 并存不破坏；
legacy `/api/notes*` 为兼容别名。mac 与 cc 同形状，cc 经隧道走 `/mem` 前缀。

## 1. 拓扑

```text
[agent]
   │  Bearer token
   ▼
┌──────────────────────────── mac（用户主操作员）───────────────────────────┐
│ clipvault-http → WebServer                                               │
│   POST /api/v1/notes            写入（saveComposeNote 唯一管线）           │
│   GET  /api/v1/notes?q&tag&since&limit                                    │
│   ...                          （端点表见 §3）                             │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ ostore trx wire（compose/tombstone/clip_link，≤4s 双向）
                ▼
┌──────────────────────────── cc（agent 记忆层）────────────────────────────┐
│ clipvault-notes :9490（notebase 引擎 + links.db + tags.db）               │
│   公网 https://<tunnel-domain>/mem/api/v1/notes*                          │
│   （caddy strip /mem；Bearer token + 每 IP 限流 + 512KB body）             │
└──────────────────────────────────────────────────────────────────────────┘
```

## 2. 请求生命周期

```text
POST /api/v1/notes {body, opId?}
  │
  ├─ 401 ── token 缺失/错误（fail closed）
  ├─ 429 ── 限流（仅 cc 公网面）
  │
  ├─ opId 已在台账？ ── 是 ──► 200 {idempotent:true, item}   不落任何写
  │
  └─ saveComposeNote / notebase oplog（唯一写管线）
         ├─ merge=false 且 parentHash≠live ──► 409 {currentHash} → rebase 重放
         ├─ tags 投影（mac note_tags / cc tags.db）
         ├─ 幂等台账（mac agent_note_ops / cc vault_meta）
         └─ trx 发布 → 对端 apply → 用户 UI 实时可见（compose_saved）
```

## 3. 端点

| 端点 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/notes` | POST | 创建/更新。`{body, title?, id?, refId?, parentHash?, merge?, opId?, agent?}` |
| `/api/v1/notes` | GET | 列表。`?q=`（FTS）·`?tag=` ·`?since=`（unix 秒）·`?limit=`（≤200） |
| `/api/v1/notes/{id}` | GET | 单篇全文（markdown 投影）+ tags |
| `/api/v1/notes/{id}` | DELETE | 软删进回收箱（30 天可撤销；与用户同一条删除路径） |
| `/api/v1/notes/{id}/links` | POST | 建链/断链 `{toId?|toHash?, kind?, linked?}` |
| `/api/v1/notes/{id}/links` | GET | 出链（`?kind=` 过滤） |
| `/api/v1/notes/{id}/backlinks` | GET | 入链（`?kind=` 过滤） |
| `/api/v1/notes/{id}/related` | GET | 推荐：tags 作 FTS 词，排除自身与已链接对端 |
| `/api/v1/notes/tags` | GET | tag 计数（只数未删） |
| `/api/v1/notes/_meta` | GET | 能力表（版本、host、端点清单） |
| `/api/v1/notes/_doc` | GET | **本文档**（markdown 自举） |
| `/api/v1/notes/_backfill` | POST | operator 一次性迁移（≤500/批，原时间戳，不发 trx） |

## 4. 状态码

| 码 | 含义 | 动作 |
| --- | --- | --- |
| 200 | 成功（`idempotent:true` 表示 opId 重放命中） | — |
| 400 | 空 body / 非法 opId / merge=false 缺 parentHash / 未知 kind | 修请求 |
| 401 | token 缺失或错误 | 取 token，勿重试原请求 |
| 404 | 开关关（与未知路由同形）/ 笔记不存在 | 查 `_meta` |
| 405 | 方法不允许 | — |
| 409 | `merge=false` CAS 冲突 `{status:"cas_conflict", currentHash}` | GET 最新 → 换 parentHash → **同 opId 重放** |
| 413 | body 超 512KB（cc 公网面） | 拆分 |
| 429 | 限流（每 IP burst 30 / 1 rps） | 按 `Retry-After` 退避 |

## 5. kind 词汇表（封闭谓词；未知值 400）

| kind | 语义 |
| --- | --- |
| `related` | 默认泛关联 |
| `mentions` | 本篇提及/引用了对方 |
| `explains` | 本篇解释/展开对方 |
| `follows` | 时序承接（续写/接续） |
| `supersedes` | 本篇取代对方（同主题新版本） |
| `contradicts` | 与对方矛盾（对照） |

## 6. 开关与凭据

| 项 | mac | cc |
| --- | --- | --- |
| 开关 | `CLIPVAULT_AGENT_API=1`（关 = 404，其余端点逐字节不变） | 常开（服务本体即 agent 面） |
| token | `CLIPVAULT_AGENT_TOKEN` env 或 `$CLIPVAULT_HOME/config/agent-token`（0600） | `<home>/notes/token`（0600）；与 mac **不同**，勿混用 |
| 归因 | `X-ClipVault-Agent` / JSON `agent` → `source="agent:<name>"` | 同 |
| token 纪律 | 永不进日志 / nmem / commit；泄漏即轮换 | 同 |

## 7. 不变量

1. **唯一写管线**：agent 写入与用户共用 `saveComposeNote()`（mac）/ notebase oplog（cc）；SSE `compose_saved` 实时可见。禁止第二写入器。
2. **用户是主操作员**：agent 不动用户 UI 语义；默认静默合并，`merge=false` 才严格 CAS。
3. **标题只由标题栏命名**：存储形如 `# title\n\nbody`；传 `title` 字段，别在 body 首行塞 H1 冒充。
4. **删除为软删**（30 天回收箱可撤销），与用户同一条路径。
5. **幂等与 CAS**：`opId` 只生效一次；`merge=false` 409 后用 `currentHash` rebase 重放。
6. **单用户 + agent 多身份**；不含多租户隔离。

## 8. 客户端

```bash
TOKEN=<cc-token>
cv-notes --base https://<tunnel-domain>/mem --token "$TOKEN" meta
cv-notes ... save --agent pi --op-id op-001 --body-file - <<'EOF'
正文…
EOF
cv-notes ... list --tag <tag> --limit 10
cv-notes ... link <note-id> --to-id <id> --kind explains
cv-notes ... related <note-id> --limit 5
```

`cv-notes` 自动协商：先打 `/api/v1/notes`，404 回退 legacy。运维脚本 `scripts/cv-notes-backfill`。
