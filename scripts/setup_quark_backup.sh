#!/bin/bash
# Prepare local staging folder for ClipVault → 夸克网盘 fan-out.
# Quark Desktop backs up *local folders* (no Google-style File Provider mount).
set -euo pipefail

STAGING="${HOME}/ClipVault-Backups/Quark"
BACKUP="${STAGING}/backup"

mkdir -p "${BACKUP}/latest" "${BACKUP}/blobs" "${BACKUP}/snapshots"
echo "Staging ready:"
echo "  ${BACKUP}"
echo ""
echo "下一步（需你在夸克客户端完成一次）："
echo "  1. 打开 Quark.app / 夸克网盘"
echo "  2. 设置 → 备份 / 上传位置 → 添加文件夹："
echo "       ${STAGING}"
echo "     或至少添加 backup 子目录"
echo "  3. ClipVault Web 侧栏启用「夸克网盘」备份源后点「立即备份」"
echo ""
if [ -d "/Applications/Quark.app" ]; then
  echo "检测到 /Applications/Quark.app — 正在打开…"
  open -a Quark 2>/dev/null || true
else
  echo "未检测到 Quark.app。可从 https://pan.quark.cn/ 下载 macOS 客户端。"
fi
