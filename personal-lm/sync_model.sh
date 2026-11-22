#!/usr/bin/env bash
# personal-lm 模型 bundle 同步（训练机 ⇄ ostore 私有 S3 ⇄ 消费机）。
#
#   sync_model.sh push     # 训练机：本地 bundle → ostore（含 cv-lm 二进制）
#   sync_model.sh pull     # 消费机（如 mac-work）：ostore → 本地，装好即可被 cv-lm 加载
#   sync_model.sh status   # 两端版本对比
#
# 传输路径：ssh <ostore host> + curl 到 cc 的 ostore API(127.0.0.1:8781)。
# OSTORE_TOKEN 只在 cc 上读取（/etc/ostore.env），永不落到任何 mac / 仓库。
# 前缀默认 clipvault/models/personal-lm/ —— 私有前缀，与剪贴板数据同域。
set -euo pipefail

CMD="${1:-status}"
SSH_HOST="${CVLM_OSTORE_SSH:-cc}"
PREFIX="${CVLM_OSTORE_PREFIX:-clipvault/models/personal-lm}"
API="${CVLM_OSTORE_API:-http://127.0.0.1:8781}"
KEEPSAKE="${KEEPSAKE_HOME:-$HOME/Library/Application Support/Keepsake}"
BUNDLE_DIR="${CVLM_BUNDLE:-$KEEPSAKE/models/personal-lm}"
BIN_DIR="$KEEPSAKE/bin"
TMP="$(mktemp -d /tmp/cvlm-sync.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

oapi() { # method path [extra curl args...]
  local method="$1" path="$2"; shift 2
  ssh -o BatchMode=yes "$SSH_HOST" \
    "T=\$(grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2); \
     curl -s -m 600 -X $method -H \"Authorization: Bearer \$T\" $* \"$API$path\""
}

local_version() {
  [ -f "$BUNDLE_DIR/manifest.json" ] || { echo "none"; return; }
  python3 -c "import json;print(json.load(open('$BUNDLE_DIR/manifest.json'))['version'])" 2>/dev/null || echo "corrupt"
}

case "$CMD" in
  push)
    [ -f "$BUNDLE_DIR/manifest.json" ] || { echo "no local bundle at $BUNDLE_DIR"; exit 1; }
    VER=$(local_version)
    echo "[push] 打包 $BUNDLE_DIR (version=$VER)"
    mkdir -p "$TMP/bundle" "$TMP/bin"
    cp "$BUNDLE_DIR"/* "$TMP/bundle/"
    [ -f "$BIN_DIR/cv-lm" ] && cp "$BIN_DIR/cv-lm" "$TMP/bin/" || echo "[push] 无本地 cv-lm 二进制，跳过"
    (cd "$TMP" && tar -czf bundle.tar.gz bundle bin)
    SHA=$(shasum -a 256 "$TMP/bundle.tar.gz" | cut -d' ' -f1)
    SIZE=$(stat -f%z "$TMP/bundle.tar.gz")
    echo "[push] 上传 ${SIZE}B → $PREFIX/bundle.tar.gz"
    ssh -o BatchMode=yes "$SSH_HOST" \
      "T=\$(grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2); \
       curl -s -m 600 -X PUT -H \"Authorization: Bearer \$T\" \
         --data-binary @- \"$API/api/files/$PREFIX/bundle.tar.gz\" \
         -o /dev/null -w 'PUT %{http_code}\n'" < "$TMP/bundle.tar.gz"
    printf '{"version":"%s","sha256":"%s","bytes":%s,"pushed_at":"%s"}\n' \
      "$VER" "$SHA" "$SIZE" "$(date -u +%FT%TZ)" > "$TMP/LATEST.json"
    # 注意：body 走 stdin 流（本地路径在远端不存在）
    ssh -o BatchMode=yes "$SSH_HOST" \
      "T=\$(grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2); \
       curl -s -m 60 -X PUT -H \"Authorization: Bearer \$T\" \
         --data-binary @- \"$API/api/files/$PREFIX/LATEST.json\" \
         -o /dev/null -w 'PUT-LATEST %{http_code}\n'" < "$TMP/LATEST.json"
    echo "[push] 完成：$VER ($SHA)"
    # 校验远端对象大小与本地一致（PUT 200 ≠ 内容到齐）
    RSIZE=$(oapi GET "/api/list?prefix=$PREFIX/" | python3 -c \
      "import json,sys;[print(e['size']) for e in json.load(sys.stdin)['entries'] if e['path'].endswith('bundle.tar.gz')]" \
      2>/dev/null || echo 0)
    [ "$RSIZE" = "$SIZE" ] || { echo "警告：远端 bundle.tar.gz 大小 $RSIZE ≠ 本地 $SIZE，请重 push"; exit 1; }
    echo "[push] 远端校验 OK ($RSIZE B)"
    ;;

  pull)
    LATEST=$(oapi GET "/api/files/$PREFIX/LATEST.json")
    VER=$(printf '%s' "$LATEST" | python3 -c "import json,sys;print(json.load(sys.stdin)['version'])")
    SHA=$(printf '%s' "$LATEST" | python3 -c "import json,sys;print(json.load(sys.stdin)['sha256'])")
    CUR=$(local_version)
    if [ "$CUR" = "$VER" ]; then echo "[pull] 已是最新 $VER，无需更新"; exit 0; fi
    echo "[pull] $CUR → $VER 下载中…"
    ssh -o BatchMode=yes "$SSH_HOST" \
      "T=\$(grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2); \
       curl -s -m 600 -H \"Authorization: Bearer \$T\" \"$API/api/files/$PREFIX/bundle.tar.gz\"" \
      > "$TMP/bundle.tar.gz"
    GOT=$(shasum -a 256 "$TMP/bundle.tar.gz" | cut -d' ' -f1)
    [ "$GOT" = "$SHA" ] || { echo "sha256 不匹配：期望 $SHA 实得 $GOT"; exit 1; }
    mkdir -p "$BUNDLE_DIR" "$BIN_DIR"
    tar -xzf "$TMP/bundle.tar.gz" -C "$TMP"
    cp "$TMP/bundle"/* "$BUNDLE_DIR/"
    if [ -f "$TMP/bin/cv-lm" ]; then
      cp "$TMP/bin/cv-lm" "$BIN_DIR/cv-lm"; chmod +x "$BIN_DIR/cv-lm"; xattr -cr "$BIN_DIR/cv-lm" 2>/dev/null || true
    fi
    NEW=$(local_version)
    [ "$NEW" = "$VER" ] || { echo "解压后版本异常：$NEW"; exit 1; }
    echo "[pull] 完成：$VER → ${BUNDLE_DIR} (cv-lm 热加载，无需重启)"
    echo "[pull] 若首次安装：见 repo LaunchAgents/com.davidmusk.clipvault-lm.plist (替换 <user> 后 bootstrap)"
    ;;

  status)
    echo "本地: $(local_version)  ($BUNDLE_DIR)"
    echo "ostore: $(oapi GET "/api/files/$PREFIX/LATEST.json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['version'], d['bytes'], 'B', d['pushed_at'])" 2>/dev/null || echo '无（从未 push）')"
    ;;

  *)
    echo "用法: sync_model.sh push|pull|status"; exit 1 ;;
esac
