#!/bin/bash
set -euo pipefail
echo "Installing Google Drive for Desktop (needs your macOS password)…"
brew install --cask google-drive
echo "Opening Google Drive…"
open -a "Google Drive" 2>/dev/null || open "/Applications/Google Drive.app" 2>/dev/null || true
echo "请在菜单栏完成 Google 账号登录。登录后应出现:"
echo "  ~/Library/CloudStorage/GoogleDrive-<email>/My Drive/"
echo "ClipVault 将自动使用: …/My Drive/ClipVault/backup/（兼容旧 Keepsake/backup）"
