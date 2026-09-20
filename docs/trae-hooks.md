# ClipVault · Trae 会话采集

会话展示读的是 **Mac 上那一份 DuckDB**，不是剪贴板 CloudDocs 同步。多机要的是 **采集进同一库**，不是每机再起一套 store。

```text
  Trae (Mac / d2 / sg_d / …)
       │  hook stdin JSON
       v
  clipvault_hook.sh
       │  先落 spool JSONL（隧道断了也不丢）
       v
  hook_client.py  ──Quack INSERT──►  quack:127.0.0.1:<local>
       │                                 │  ssh -R  (远端)
       │                                 v
       │                    Mac quack:127.0.0.1:9494
       │                                 │
       │                                 v
       │                    hook_events.duckdb   唯一 writer
       │                                 │
       └─ (仅本机) HTTP ping :9488 ──► server.py SSE
                                         │
                                         v
                    ClipVault :8080  /trae/?embed=1
```

| 角色 | 跑什么 | 不跑什么 |
| --- | --- | --- |
| **Mac store** | `trae_hooks/server.py`（LaunchAgent `com.davidmusk.clipvault-trae`） | 第二份 DuckDB |
| **采集端**（本机 Trae 或远端 Trae） | hook 包装器 + `duckdb` **client** + Quack 扩展 + spool flush | `server.py`、`:9488`、自己的 `.duckdb` 库 |

禁止：把会话做成 clip 的 `trx/{host}/{seq}`；每台开发机再部署一份 DuckDB server。

---

## 三个问题

### 1. 当前 session 是本地数据吗？要不要「同步」？

是。真源是 Mac 文件：

`$CLIPVAULT_HOME/trae/hook_events.duckdb`

（现网 `~/Documents/ClipFlow/trae/hook_events.duckdb`）

UI 只经本机 `127.0.0.1:9488`，再由 ClipVault `:8080` 反代 `/trae`。**没有** CloudDocs 双向同步。

要的能力是「d2 / sg_d 上的 Trae 也出现在同一会话墙」——这是 **采集汇入**，已经有：远端 hook → Quack → Mac DuckDB。不要再复制一套库。

### 2. 加了采集之后，每台机器都要部署 DuckDB server 吗？

**不要。** DuckDB 单 writer。只有 Mac 跑 `server.py`（HTTP `:9488` + `quack_serve :9494`）。

每台 Trae 机器只要：

```text
hooks.json → clipvault_hook.sh → venv(duckdb 1.5.5 + quack)
           → spool JSONL → systemd flush
           → quack:127.0.0.1:<Rport>  （ssh -R 接到 Mac :9494）
```

`instance_id` 区分来源（`mac-work` / `d2` / `sg_d`）。

### 3. 多机 hook，Quack 能不能完成采集？

能。Quack 是写协议（带 token 的远程 SQL INSERT），不是第二份 UI。

```text
Mac     CLIPVAULT_QUACK_URI=quack:127.0.0.1:9494     本机直连
d2      quack:127.0.0.1:19494   ssh -R → Mac :9494   隧道 clipvault-quack-d2
sg_d    quack:127.0.0.1:19495   ssh -R → Mac :9494   隧道 clipvault-quack-sg_d
```

隧道断了：hook **exit 0**（不挡 Trae），行先在 `/var/tmp/clipvault-hooks/spool`；`clipvault-hook-flush.service` 每 15s 重试。

远端 **不会** 打到 Mac 的 `:9488` SSE。远端新事件靠面板 `resync` / 心跳补，不靠本机 EventSource。

---

## Metrics 平面（成本 / 缓存 / tok·s / 上下文构成）

`hook_events` 只存**内容**（prompt / 工具 / 回复）。词频能算，钱和效率算不出来：
它没有 token / cache / model / cost 任何一列。所以指标是**另一条平面、另一组表**，
靠 `session_id + ts` 与内容表关联。

```text
                       一次 assistant 回复
                             │
      ┌──────────────────────┼────────────────────────┐
      ▼                      ▼                        ▼
 hook_events            llm_usage                 turn_context
 内容 / 行为             钱 + 速度                  上下文构成
 ────────────           ──────────────────        ───────────────────
 PreToolUse             in / out / reasoning       system 分段估算
 PostToolUse            cacheRead / cacheWrite     rules / skills / project
 UserPromptSubmit       cost.{in,out,cache}        history 累计
 Stop / Notification    model / provider / api     skill_loaded_tokens
                        ttft / elapsed / tok·s     memory_ids
      └─────────────── join: session_id + ts ───────────────┘
```

| 表 | 粒度 | 主键 | 谁写 |
| --- | --- | --- | --- |
| `llm_usage` | 一条 assistant message | `<session>:<message.timestamp>` | 热路径 + 冷路径 |
| `turn_context` | 同上 | `<session>:<message.timestamp>` | 冷路径 |

两个 writer，同一主键，互不重复：

- **热路径** `pi/clipvault-session.ts` → `UsageReport` → `hook_client.py` 直接写 `llm_usage`。
  唯一能拿到 `ttft_ms` 的 writer（JSONL 不存 ttft）。
- **冷路径** `pi_session_ingest.py` 读 `~/.pi/agent/sessions/**/*.jsonl` 回填两表。
  无损、可回溯历史、有 system `sections`，但**没有 ttft**。
  用 `ON CONFLICT ... DO UPDATE`，并 `COALESCE` 保住热路径的 `ttft_ms/decode_ms/tok_s_decode`。

关键事实（踩过坑，别改）：

- `message.timestamp` = **请求开始**，`entry.timestamp` = **完成**。`elapsed = 完成 − 开始`；
  用相邻消息时间差会得到 1ms（错）。
- Trae hook stdin **没有** usage/model/cost（实测只有 `session_id/tool_name/tool_input…`），
  所以 metrics 平面只有 pi 能喂。
- `hook_events` 里的 usage 相关事件为 0：`hook_client.py` 按 `METRIC_EVENTS` 分流，
  `UsageReport`/`ContextReport` 不走 spool、不进 `hook_events`。

### 采集

```bash
# 一次性回填（可重复运行，幂等）
/Users/bytedance/.trae-cn/hooks_env/pi_session_ingest.sh --since 0
# 只解析不写：  … --dry-run   ；导出： … --out /tmp/metrics.ndjson
```

定时：LaunchAgent `com.davidmusk.clipvault-metrics`，每 15 分钟 `--since 3`（`trae_hooks/com.davidmusk.clipvault-metrics.plist`，`install.sh` 会装）。

### 读

面板方向 `agent.metrics`（`/api/mine`）：总览 / 按模型 / 上下文构成 / 每天成本曲线 / Skill 上下文成本。
判读口径：

- **缓存命中率** = `cacheRead / (cacheRead + 未缓存 input)`。前缀（rules / AGENTS / skills）一改，整段失效。
- **tok/s** 优先看 decode（`output / (elapsed − ttft)`）；`tok_s_e2e` 含工具时间，天然偏低。
- **上下文 tokens 是估算**（`chars / 校准 cpt`）。块 note 里有「估算/实测」比，接近 1 才可信。
- **Skill 上下文成本** = 该 skill 文件**被读进上下文**的正文 tokens（按 toolResult 实测），
  不是 system 里常驻的 skills 索引；写/改 skill 文件的确认回执不计入。

---

## 端口与身份

| 谁 | 口 | 绑定 |
| --- | ---: | --- |
| Mac Quack | 9494 | `127.0.0.1`（禁止 LAN） |
| Mac Trae HTTP | 9488 | `127.0.0.1`；浏览器只走 `:8080/trae` |
| d2 回连 | 19494 | 远端 loopback → Mac 9494 |
| sg_d 回连 | 19495 | 同上 |

token：`$CLIPVAULT_HOME/config/trae-quack.token`（chmod 600）。只 scp 到远端 `hooks_env/quack.token`，禁止进 git / nmem / 聊天。

---

## Mac store（已有则跳过）

```bash
# 仓库根
bash trae_hooks/install.sh
# LaunchAgent com.davidmusk.clipvault-trae
# 探针：curl -fsS --noproxy '*' http://127.0.0.1:9488/api/health
```

UI：ClipVault 顶栏「会话」。禁止浏览器直开 `:9488`。

---

## 远端采集端（d2 / sg_d / 下一台）

在 **Mac** 上跑，不要登录上去手装一套。

```bash
# d2（历史入口，等价下面那行）
bash trae_hooks/install_d2.sh

# sg_d
CLIPVAULT_REMOTE_SSH=sg_d \
CLIPVAULT_INSTANCE_ID=sg_d \
CLIPVAULT_REMOTE_QUACK_PORT=19495 \
  bash trae_hooks/install_remote.sh
```

脚本会：scp 包装器 / client / token → 远端 `~/.trae-cn/hooks_env`（路径无空格，Trae `bash -c` 不引号）→ venv + `duckdb==1.5.5` + `LOAD quack` → 写 `hooks.json` + systemd flush。

然后 **隧道**（本机管控台 `http://127.0.0.1:9020`）：

| name | 远端 listen | 本机 |
| --- | --- | --- |
| `clipvault-quack-d2` | `127.0.0.1:19494` | `:9494` |
| `clipvault-quack-sg_d` | `127.0.0.1:19495` | `:9494` |

```bash
curl -sS -X POST http://127.0.0.1:9020/api/tunnel/clipvault-quack-sg_d/start
# 或一次性：
ssh -fN -o ExitOnForwardFailure=yes -o BatchMode=yes \
  -R 127.0.0.1:19495:127.0.0.1:9494 sg_d
```

**Trae 必须硬重启远端 server** 才会加载新 `hooks.json`。Remote SSH 只重连窗口会复用已有 `server-main.js`，hook 不会生效。

在 sg_d 上停掉旧 server 再从 Mac 连一次，或 Trae 设置里对远程窗口启用全局 Hooks + 自动运行。

---

## sg_d 现状（2026-09-09）

| 项 | 值 |
| --- | --- |
| SSH | `Host sg_d` · `10.251.225.85` · `User root` |
| Trae | `/root/.trae-cn-server` 已在跑；尚无 `hooks.json` |
| Python | `/root/.local/bin/python3.11`（系统 3.7 不可用） |
| 本机 Python | 禁止 3.7 装 duckdb 1.5.5 |

---

## 自检

```bash
# Mac store
curl --noproxy '*' -fsS http://127.0.0.1:9488/api/health

# 采集端到底在不在工作（"active" != 在工作）；也可 ssh 远端跑
ssh d2 'bash /root/.trae-cn/hooks_env/collector_selfcheck.sh'
#   查三个静默故障：env 写成 export（systemd 忽略）／进程 environ 为空／隧道不通

# 隧道起来后，在远端
nc -z 127.0.0.1 19495 && echo quack_tunnel_ok

# 库里按机看
# instance_id in ('mac-work','d2','sg_d')
```

`trae-hooks.env` 必须是 systemd `KEY=value`（不要 `export`）。包装器 `set -a` 后再 source。**改完 env 必须 `systemctl restart clipvault-hook-flush`**：`enable --now` 不会重启已在跑的 unit，旧进程会继续用空环境（d2 曾因此积压 3.9G 未上传）。`install_remote.sh` 已改成 `enable` + `restart`，并在末尾自动跑 `collector_selfcheck.sh`。

`trae-hooks.env` 必须是 systemd `KEY=value`（不要 `export`）。包装器 `set -a` 后再 source。

hook 失败必须 **exit 0**。排障看远端 `/var/tmp/clipvault-hooks/wrapper.err`、`quack.err`、`spool/flush.err`。

---

## pi 会话（可选）

pi 没有 `hooks.json`，用 **extension** 当适配器，把 pi 生命周期事件映射成 ClipVault hook 契约，再走同一个 `clipvault_hook.sh`（spool + Quack + SSE）。

```text
  pi 事件                  ClipVault hook_event   映射
  ----------------------  ---------------------  ----------------------------------
  session_start            SessionStart           startup / new / resume / fork
  before_agent_start       UserPromptSubmit       prompt（input.source=extension 的不算）
  tool_execution_start     PreToolUse             tool_name / tool_input
  tool_result              PostToolUse            wall_time_seconds + isError->exit_code
  agent_settled            Stop                   last_assistant_message
  ui_prompt_start          Notification           pi 在等人（ask_user_question）
```

工具名归一化到 `mine.py` 能认的名字：`bash`→`RunCommand`，`read/write/edit` 原样，`grep/find/ls`→`RunCommand` 并合成 shell 形态的 `cmd`，`nmem_*`→`mcp__nowledge-mem__*`（这样 MCP 只读不沉降的分析也能用）。

装：

**本机（Mac store 已在时）：**

```bash
bash trae_hooks/pi/install_pi_hook.sh
# 写 ~/.trae-cn/hooks_env/pi-hooks.env（source trae env 后只改 identity）
# symlink ~/.pi/agent/extensions/clipvault-session.ts -> repo
```

**远端（Trae 采集端已在时；sg_d / d2 这类 Linux 机）：**

```bash
CLIPVAULT_REMOTE_SSH=sg_d bash trae_hooks/pi/install_pi_hook_remote.sh
# 写 <hooks_env>/pi-hooks.env（同上，identity 继承该机 instance_id）
# 落一份真文件 <home>/.pi/agent/extensions/clipvault-session.ts（非 symlink）
```

`install_remote.sh` 已把这一步并进新机安装：装采集端即同时装 pi 适配器，pi 捕获是每台采集端的标准件。

然后重启 pi（或 `/reload`）。pi 会话与 Trae 共用该机 `instance_id`（Mac `mac-work`、sg_d `sg_d`），靠 `source=pi` 区分。单次关闭：`CLIPVAULT_PI_SESSION_HOOK=0 pi`。

**不影响 pi 主流程**：适配器 spawn 包装器后立即 `unref()`，不 await；包装器自身失败也 `exit 0`。

---

## 代码

| 路径 | 职责 |
| --- | --- |
| `trae_hooks/server.py` | 唯一 DuckDB writer + HTTP + `quack_serve` |
| `trae_hooks/hook_client.py` | spool + Quack INSERT；`UsageReport`/`ContextReport` 分流到 metrics 平面 |
| `trae_hooks/metrics.py` | metrics 平面的列定义 / 行构造 / INSERT·UPSERT SQL |
| `trae_hooks/pi_session_ingest.py` | 冷路径回填：pi session JSONL → `llm_usage` / `turn_context` |
| `trae_hooks/pi_session_ingest.sh` | 回填包装器（LaunchAgent 用） |
| `trae_hooks/com.davidmusk.clipvault-metrics.plist` | 定时回填（15m） |
| `trae_hooks/install.sh` | Mac store + 本机 hook |
| `trae_hooks/install_remote.sh` | 任意 SSH 采集端（含 pi 适配器 + 自检） |
| `trae_hooks/collector_selfcheck.sh` | 采集端自检（env 可见性 / 隧道 / spool） |
| `trae_hooks/pi/install_pi_hook_remote.sh` | 远端 pi 适配器（复用已装采集端） |
| `trae_hooks/install_d2.sh` | `install_remote.sh` 的 d2 预设 |
| `~/bin/ssh-socks-server.py` | 反向隧道条目（活的 9020） |
