# ostore 冷备

ClipVault 在本机备份成功后，把该主机的数据库和 CAS 媒体增量复制到 ostore。备份不参与多机同步。每台机器使用独立的 `hostId`。

## 配置

在 ClipVault 数据目录的 `config/ostore-backup.json` 写入以下格式，权限设为 `0600`。密钥只放服务端，禁止提交或下发到浏览器。

```json
{"baseURL":"https://cc.guohuasun.com/ostore","token":"<OSTORE_TOKEN>"}
```

地址必须为 HTTPS。当前 cc 实例使用 JSON API，和 xstream 共用访问令牌与存储根目录；ClipVault 仅写 `clipvault/` 前缀。

## 运行和状态

本机备份成功或内容未变时自动排队；`POST /api/backup/ostore/run` 先运行本机备份，再异步上传。`GET /api/backup/status` 的 `ostore` 包含配置、阶段、最近成功时间、错误和本轮上传/跳过数量。运行状态保存在进程内，重启后重新开始统计。Web 备份面板展示同一状态。

```text
local sqlite3_backup + verified CAS
    -> hosts/H/latest + hosts/H/blobs
    -> ostore clipvault/backup/hosts/H/blobs
    -> ostore clipvault/backup/hosts/H/databases/SHA.db
    -> ostore clipvault/backup/hosts/H/latest/{clipflow.db,MANIFEST.json}
```

逐文件 SHA-256 对账，已有对象跳过，上传响应的 SHA-256 必须匹配。数据库与清单不匹配、媒体缺失、鉴权或网络错误时报告失败；本机备份不回滚。最新清单最后上传，但两个 latest 文件不是原子事务；上传中断时 `latest/clipflow.db` 可能与清单不一致，恢复时必须校验。数据库内容寻址副本保留当前和上一个版本；媒体不会自动删除。

## 灾难恢复

在隔离目录下载对应 host 的 `latest/MANIFEST.json`，使用其 `sha256` 下载 `databases/<sha256>.db`，按 `blobFiles` 下载 `blobs/`，逐个校验文件完整性。清单中 `sha256` 是数据库 SHA-256；若使用 `latest/clipflow.db`，必须先与此值比较。检查 SQLite `PRAGMA integrity_check` 后，再按现有 ClipVault 恢复流程操作。不要把远端备份当成同步总线，也不要直接覆盖正在使用的数据库。
