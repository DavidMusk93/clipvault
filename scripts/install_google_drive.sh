#!/bin/bash
# Install Google Drive for Desktop. Prefers brew; falls back to cached DMG GUI installer
# when non-interactive sudo is unavailable (common in agent shells).
set -euo pipefail

if [ -d "/Applications/Google Drive.app" ]; then
  echo "Already installed: /Applications/Google Drive.app"
  open -a "Google Drive" 2>/dev/null || open "/Applications/Google Drive.app" 2>/dev/null || true
  echo "请在菜单栏完成 Google 账号登录。登录后应出现:"
  echo "  ~/Library/CloudStorage/GoogleDrive-<email>/My Drive/"
  echo "ClipVault 将自动使用: …/My Drive/ClipVault/backup/（兼容旧 Keepsake/backup）"
  exit 0
fi

echo "Installing Google Drive for Desktop (needs your macOS password)…"
if brew install --cask google-drive; then
  :
else
  echo "brew 非交互安装失败（常见原因：sudo 需要密码）。改用图形安装程序…"
  # Ensure artifact present
  brew fetch --cask google-drive >/dev/null 2>&1 || true
  DMG="$(brew --cache --cask google-drive 2>/dev/null || true)"
  if [ -z "${DMG}" ] || [ ! -f "${DMG}" ]; then
    DMG="$(find "$(brew --cache)/downloads" -name '*GoogleDrive*.dmg' 2>/dev/null | head -1 || true)"
  fi
  if [ -z "${DMG}" ] || [ ! -f "${DMG}" ]; then
    echo "未找到 GoogleDrive.dmg，请手动: brew install --cask google-drive"
    exit 1
  fi
  MNT="$(hdiutil attach "${DMG}" -nobrowse -readonly 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)"
  PKG="${MNT}/GoogleDrive.pkg"
  if [ ! -f "${PKG}" ]; then
    echo "DMG 内无 GoogleDrive.pkg: ${MNT}"
    exit 1
  fi
  open "${PKG}"
  echo "已打开图形安装程序，请在弹窗中输入密码完成安装。"
  echo "安装完成后重新运行本脚本，或直接 open -a 'Google Drive' 并登录。"
  exit 0
fi

echo "Opening Google Drive…"
open -a "Google Drive" 2>/dev/null || open "/Applications/Google Drive.app" 2>/dev/null || true
echo "请在菜单栏完成 Google 账号登录。登录后应出现:"
echo "  ~/Library/CloudStorage/GoogleDrive-<email>/My Drive/"
echo "ClipVault 将自动使用: …/My Drive/ClipVault/backup/（兼容旧 Keepsake/backup）"
