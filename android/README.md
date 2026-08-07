# ClipVault Android

手机端 **备份阅读器 + 主动粘贴/分享**。采集与 CAS 备份仍在 Mac 的 ClipFlowServer；本 App 只读 Google Drive（或任意）上的 `ClipVault/backup` 目录（兼容旧名 `Keepsake/backup`）。

## 能力（v0.1）

| 功能 | 说明 |
| --- | --- |
| 选备份目录 | SAF 选中 `…/My Drive/ClipVault/backup`（或旧 `Keepsake/backup`）（含 `latest/`、`blobs/`） |
| 列表 / 搜索 | 读 `latest/clipflow.db`（缓存到本机） |
| 图片 | 按 `content_hash` 从 `blobs/{hash}.bin` 加载 |
| 复制回去 | 详情页一键写入系统剪贴板 |
| 粘贴保存 | 前台读取剪贴板 → 本机捕获队列 |
| 系统分享 | 分享文本 → 本机捕获队列 |

**不做：** 后台常驻监听剪贴板。

## 本地构建

```bash
cd android
./gradlew :app:assembleRelease
# 产物
# app/build/outputs/apk/release/app-release.apk
```

要求：JDK 17、Android SDK 34。CI 用仓库内 `keystore/keepsake-ci.jks` 签名（**仅适合自用旁加载**，不是 Play 上传密钥）。

## 安装

1. 手机开启「允许安装未知应用」
2. 下载 CI Artifact / GitHub Release 中的 `keepsake-*.apk`
3. 安装后打开 → **选择备份目录** → Google Drive → `ClipVault/backup`（或旧 `Keepsake/backup`）
4. 建议在 Drive App 里对该文件夹开启 **离线可用**

## 目录约定（与 Mac 一致）

```
ClipVault/backup/
  latest/clipflow.db
  latest/MANIFEST.json
  blobs/{sha256}.bin
  blobs/{sha256}.rtf.bin
  STATUS.json
  snapshots/...
```

## CI 产物

- 每次 `master` push：上传 `keepsake-debug.apk` + `keepsake-release.apk` 为 workflow artifact  
- 打 tag `v*`：创建 GitHub Release 并附带 release APK  

版本号可用环境变量覆盖：`KEEPSAKE_VERSION_NAME` / `KEEPSAKE_VERSION_CODE`。
