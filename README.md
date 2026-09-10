# ClipVault

**遇到的留下，想到的写下。**

个人 Mac 剪贴板记忆：本机守护进程静默捕获，浏览器检索与预览，图片 OCR 可检索，备份进你自己的云盘。

## 架构

```text
ClipVault
├── Sources/ClipVault/      # Swift daemon（SPM product ClipVaultServer）
│   ├── App/                # 入口
│   ├── HTTP/               # CV01 origin + 拉起 clipvault-http
│   ├── Capture/            # 剪贴板 / OCR
│   ├── Store/              # SQLite
│   ├── Sync/               # CloudDocs 同步 + 备份
│   ├── Archive/            # WKWebView 归档
│   └── Metrics/
├── http-front/             # 唯一 HTTP 层：HTTP/2（h2c :80 / TLS :443）
├── web/                    # 浏览器控制面
├── android/                # 备份阅读器 + 粘贴/分享
└── LaunchAgents/           # com.davidmusk.clipvault
```

| 层 | 选择 |
| --- | --- |
| 语言 | Swift 5.9 · macOS 13+ ；HTTP 边车 Rust |
| 存储 | SQLite3（`clipflow.db` 文件名兼容） |
| 网络 | 一层 HTTP/2：`clipvault-http`；Swift origin 是 CV01 |
| OCR | Vision |
| 备份 | iCloud Drive / Google Drive / 夸克（无 App iCloud entitlement） |

## 快速开始

```bash
git clone https://github.com/DavidMusk93/clipvault.git
cd clipvault
./scripts/deploy-server.sh
```

本机 UI：`http://127.0.0.1:8080`（LaunchAgent 默认听 8080；代码默认 :80，macOS 用户进程绑不了特权端口）。

```bash
swift build -c release --product ClipVaultServer
./scripts/check-frontend.sh
```

## 数据目录

LaunchAgent 必须设 `CLIPVAULT_HOME`（兼容 `KEEPSAKE_HOME`）。禁止 `nohup ClipVaultServer &`（incident 2026-08-11）。

```text
~/Library/Application Support/Keepsake/   # 现行本机库路径
├── clipflow.db
├── blobs/
└── web/
```
