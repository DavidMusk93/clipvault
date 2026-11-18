# 事故复盘：错误数据目录导致「历史丢失」观感（2026-08-11）

## 一句话结论

**未删除用户历史**；以 `nohup ClipFlowServer` **裸启**且未带 `KEEPSAKE_HOME`，进程落到空的 App Support 库，UI 显示空白，真库仍在 `~/Documents/ClipFlow`。

## 时间线（CST）

| 时间 | 事件 |
| --- | --- |
| ~11:12–11:23 | 为上线「纯文本复制」替换二进制；用 `kill` + `nohup` 重启 |
| 同时 | 空库出现在 `~/Library/Application Support/Keepsake/clipflow.db`（4KB） |
| 用户反馈 | 「历史丢失」 |
| 排查 | 真库 `~/Documents/ClipFlow/clipflow.db` 仍在（~3MB，~410 条） |
| 恢复 | `launchctl bootstrap` 按 plist 启动，`KEEPSAKE_HOME=Documents/ClipFlow` |

## 根因链

```
agent 部署二进制
  → kill 旧进程
  → nohup ClipFlowServer &     # 无 LaunchAgent 环境
  → 未设置 KEEPSAKE_HOME / CLIPVAULT_HOME
  → resolveDataRoot 落到 Application Support/Keepsake
  → 新建/打开近乎空的 clipflow.db
  → :8080 读空库 → UI「历史没了」
真库 Documents/ClipFlow 从未被 rm / DROP
```

### 为何会落到 App Support

`DatabaseManager.resolveDataRoot()`（事发时逻辑）：

1. 有 `CLIPVAULT_HOME` / `KEEPSAKE_HOME` → 用之  
2. 在 launchd 且无 env → App Support（TCC 顾虑）  
3. 交互式 → 若 Documents 有 `clipflow.db` 则用之，否则 App Support  

`nohup` 不注入 plist 环境；再叠加路径探测边界，即可打开**错误空库**并照常监听 8080。

## 影响

| 项 | 说明 |
| --- | --- |
| 用户可见 | 剪贴板历史像被清空 |
| 数据 | **未删**真库；夸克快照仍在 |
| 信任 | 极高严重度（数据主观丢失） |

## 已做防护（防再发）

| 层 | 措施 |
| --- | --- |
| 代码 | `resolveDataRoot`：拒绝「空家」盖住大库；launchd 无 env 且无大库则 `exit(1)` |
| 代码 | `assertDataHomeSaneOrExit`：items&lt;5 且另一路径有 ≥64KB db → FATAL |
| 脚本 | `scripts/restart-clipflow.sh`：只走 launchctl |
| 脚本 | `scripts/verify-data-home.sh`：重启后必验 |
| 脚本 | `scripts/deploy-server.sh`：build + 安全重启 |
| 文档 | 本文件 + `AGENTS.md` 硬规则 |

## 硬规则（agent / 人）

1. **禁止** `nohup …/ClipFlowServer &` 或直接前台启动替代 LaunchAgent  
2. **只许** `./scripts/restart-clipflow.sh` 或 `./scripts/deploy-server.sh`  
3. 重启后必须 `./scripts/verify-data-home.sh` 通过  
4. 改二进制前确认 plist 含 `KEEPSAKE_HOME` 或 `CLIPVAULT_HOME`  
5. 用户说「历史没了」→ **先比两处 db 体积与 sqlite count**，禁止先「重建」或删库  

## 恢复手册（若再次指错 home）

```bash
# 1) 确认真库
ls -la ~/Documents/ClipFlow/clipflow.db
sqlite3 ~/Documents/ClipFlow/clipflow.db 'SELECT COUNT(*) FROM clipboard_items;'

# 2) 正确重启
./scripts/restart-clipflow.sh

# 3) 校验
./scripts/verify-data-home.sh
```

若真库损坏，再动夸克/iCloud 快照：`~/ClipVault-Backups/Quark/backup/snapshots/`。

## 责任

Agent 在部署路径上选择了不安全重启方式；属可避免的操作事故，不是产品随机丢数据。
