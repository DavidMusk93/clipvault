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

### P0 · 能力表

```text
GET /api/notes/_meta
→ { ok, api:"clipvault-notes", version:"p0", endpoints:{...} }
```

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
4. **删除（P2 起）为软删进回收箱**，可撤销。
5. 单用户 + agent 多身份；本产品不含多租户隔离。
