# Agent Usage · ClipVault 笔记 API

给编码 agent 的最小使用说明。契约真源：`AGENTS.md · 笔记`；本文件只讲怎么调。
能力随 patch 增长，每节标注阶段（P0 骨架 → P1 读 → P2 写 → P3 链接 → P4 生态）。

## 开关与鉴权

| 项 | 值 |
| --- | --- |
| 开关 | LaunchAgent env `CLIPVAULT_AGENT_API=1`；关闭时 `/api/notes*` 一律 404，其余端点逐字节不变 |
| token | env `CLIPVAULT_AGENT_TOKEN` 优先，否则 `$CLIPVAULT_HOME/config/agent-token`（0600，单行） |
| 携带 | `Authorization: Bearer <token>` 或 `X-ClipVault-Token: <token>` |
| 归因 | JSON `agent` 字段或 header `X-ClipVault-Agent: <name>` → 库内 `source="agent:<name>"`（小写 `[a-z0-9-_]`，≤32，兜底 `agent`） |

token 缺失（env 与文件都没有）= 一律 401，fail closed。token 永不进日志 / nmem / commit。

## 端点

### P0 · 写入

```text
POST /api/notes
  { "body": "markdown 全文（必填）",
    "title": "可选，标题栏命名（标题只由标题栏命名，勿在 body 里放 H1 冒充）",
    "id": "可选 UUID，传了即更新既有笔记",
    "refId": "可选，关联来源 clip/note id",
    "parentHash": "可选 CAS；不传走默认静默合并",
    "agent": "pi" }
→ 200 { ok, item, conflict, merged, source }
   400 空 body / 非法 JSON
   401 token 错
   404 开关关（与未知路由同形）
   409 不适用（P0 不返回；P2 显式 merge=false 时才有）
```

### 能力表

```text
GET /api/notes/_meta
→ { ok, api:"clipvault-notes", version:"p2a", endpoints:{...} }
```

### P1 · 读

```text
GET /api/notes?q=<fts>&tag=<tag>&since=<unix 秒>&limit=<1..200，默认 50>
  → { ok, count, notes:[ itemToJSON + tags:[".."] ] }   按更新时间倒序
  q   走既有 clipboard_fts（trigram/unicode61 自适应，bm25 语义与墙一致）
  tag 小写精确匹配（note_tags 投影，服务端提取，同前端 #tag 语义）
  since  只回 timestamp > since 的行（笔记更新时间；保存即推进）——增量拉取用
GET /api/notes/{id}
  → { ok, item(json), tags:[..] }
GET /api/notes/tags
  → { ok, tags:[ {tag, count} ] }   count 倒序，只数未删除笔记
```

`note_tags` 是新增投影：保存时服务端从 markdown 提取（围栏外 `#tag`，
同前端 `extractNoteTags` 语义），首次启动回填存量笔记。前端 `#tag` 交互不动。

### P2a · 写语义（幂等 + CAS）

```text
POST /api/notes 增参：
  opId        JSON 或 header X-ClipVault-Op-Id；[A-Za-z0-9._:-]{1,128}
              同 opId 重放 → 200 { ok, idempotent:true, item, tags, source }，不再写
  merge       默认 true（与用户路径一致：三方合并静默）；false = 严格 CAS
  merge=false 更新必须带 parentHash；parentHash != 当前 contentHash →
              409 { ok:false, status:"cas_conflict", currentHash }
              → GET /api/notes/{id} 拉最新，带新 parentHash 重放
agent 端点错误用真实状态码：400（空 body / 非法 opId / merge=false 缺 parentHash）、
409（CAS）、401/404/405 同 P0。
```

```bash
# CAS 冲突重放示例
H1=$(curl -sS ... -X POST http://127.0.0.1/api/notes \
  -H "Authorization: Bearer $TOKEN" -H "X-ClipVault-Op-Id: op-001" \
  -d '{"id":"UUID","body":"新内容","parentHash":"旧hash","merge":false}')
# 409 → currentHash；用 currentHash 作为新 parentHash 再发同一 opId → 200

## 示例

```bash
TOKEN=$(cat "$CLIPVAULT_HOME/config/agent-token")
curl -sS --noproxy '*' -X POST http://127.0.0.1/api/notes \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-ClipVault-Agent: pi" \
  -H 'Content-Type: application/json' \
  -d '{"body":"# 会话结论\n\nTUDP Cube archive 起点用既有 RG start。","agent":"pi"}'
```

## 不变量（agent 必须遵守）

1. **唯一写管线**：agent 写入与用户共用 `saveComposeNote()`；用户 UI 会通过 SSE `compose_saved` 实时看到 agent 的编辑。禁止 agent 直写 SQLite 或绕过该管线。
2. **用户是主操作员**：agent 不动用户 UI 语义；合并冲突默认静默合并（与用户路径一致）。
3. **标题只由标题栏命名**：存储形如 `# title\n\nbody`；传 `title` 字段，别在 body 首行塞 H1 冒充标题。
4. **删除（P2b 起）为软删进回收箱**，可撤销。
5. **幂等与 CAS（P2a 起）**：写入带 `opId` 则同 opId 只生效一次；`merge=false` 走严格 CAS，409 后用 `currentHash` rebase 重放。
6. 单用户 + agent 多身份；本产品不含多租户隔离。
