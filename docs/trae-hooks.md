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

# 隧道起来后，在远端
nc -z 127.0.0.1 19495 && echo quack_tunnel_ok

# 库里按机看
# instance_id in ('mac-work','d2','sg_d')
```

`trae-hooks.env` 必须是 systemd `KEY=value`（不要 `export`）。包装器 `set -a` 后再 source。

hook 失败必须 **exit 0**。排障看远端 `/var/tmp/clipvault-hooks/wrapper.err`、`quack.err`、`spool/flush.err`。

---

## 代码

| 路径 | 职责 |
| --- | --- |
| `trae_hooks/server.py` | 唯一 DuckDB writer + HTTP + `quack_serve` |
| `trae_hooks/hook_client.py` | spool + Quack INSERT |
| `trae_hooks/install.sh` | Mac store + 本机 hook |
| `trae_hooks/install_remote.sh` | 任意 SSH 采集端 |
| `trae_hooks/install_d2.sh` | `install_remote.sh` 的 d2 预设 |
| `~/bin/ssh-socks-server.py` | 反向隧道条目（活的 9020） |
