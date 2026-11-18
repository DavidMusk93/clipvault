---
doc_id: clipvault-decision-single-user-agent-identities-v1
kind: decision
status: active
authority: design
applies_to:
  - cc-notes/src/main.rs
  - docs/references/agent-api-v1.md
depends_on:
  - AGENTS.md
supersedes: []
verified_by:
  - scripts/check-doc-guard.sh
---

# 决策：单用户 + agent 多身份，不做多租户账号系统

## 背景

cc 记忆层（`xyz69.top/mem`）公网可达，鉴权目前是 token + 限流。「多账号系统」曾作为候选迭代提出。

## 决策依据（项目定义为准）

| 项目定义（`AGENTS.md · 身份`） | 对账号面的含义 |
| --- | --- |
| 「个人记忆：静默捕获世界 + 主动写下自己」 | 库是一个人的一段记忆，不是一份多租户数据 |
| 「不是企业协同剪贴板、Notion 替代」 | 账号/工作区/共享权限体系是另一个产品 |
| 用户是主操作员；agent 多身份 | 「多账号」的**正确形态** = 多 agent 身份（已落地：`tokens.json` 按名归因） |

`clipvault_design_philosophy_layered_memory`：正确性交给浏览器引擎，陪伴感留在产品里 —— 账号墙与陪伴感互斥。

## 决定

1. **不建**注册/登录/工作区/多租户隔离。
2. 身份面 = **单用户（Owner）+ agent 多身份**：tokens.json 签发、按名归因、可轮换撤销（删条目即撤销，改文件即生效）。
3. 公网暴露面的安全边界继续是：Bearer token + 每 IP 限流 + 512KB body + 单用户数据。若未来 Owner 明确要做「面向真正用户的多人产品」，那是新立项（新 goalx），不回改本决策。

## 后果

- 简化：无账号数据库、无会话过期、无租户隔离审计面。
- 边界：token 泄漏 = 该 agent 身份可写（0600 存放 + 轮换）；不做防滥用到租户粒度。
