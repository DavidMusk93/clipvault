#!/usr/bin/env bash
# personal-lm 模型 bundle 同步（训练机 ⇄ ostore 私有 S3 ⇄ 消费机）。
#
#   sync_model.sh push     # 训练机：本地 bundle → ostore（含 cv-lm 二进制）
#   sync_model.sh pull     # 消费机（如 mac-work）：ostore → 本地，装好即可被 cv-lm 加载
#   sync_model.sh status   # 两端版本对比
#
# 传输路径（v2，2026-11-23 实测选型）：
#   1) 快路：HTTPS 直连 ostore 公网 API（caddy /ostore → cc:8781）≈454KB/s
#   2) 兜底：ssh $SSH_HOST 中继 → cc 本机 curl 127.0.0.1:8781 ≈187KB/s
#   公网直连需要 OSTORE_TOKEN：每次在 cc 上临时读取，永不落任何 mac / 仓库。
# 断点续传（服务端零改动）：
#   push 把 bundle 切成 8MB 分片传到 <prefix>/parts/，回读 /api/list 校验大小，
#   已存在且大小一致的分片直接跳过 → 中断重跑只补缺的部分；
#   清单 bundle.parts.json（全量 sha256 + 分片 sha256 + 元数据）最后原子写入。
#   pull 按 parts.json 逐片下载（本机 /tmp/cvlm-parts/<ver>/ 已有且 sha 一致的分片
#   不重复下载 → 拉取方向同样可断点续传），拼合后全量 sha256 校验再安装。
#   旧版单文件 bundle.tar.gz 流程保留（无 parts.json 的历史 bundle 仍可 pull）。
# 隐私：语料/bundle 是个人私有，只走 ostore/gdrive 私有前缀，绝不进 git/公共 Hub。
set -euo pipefail

CMD="${1:-status}"
SSH_HOST="${CVLM_OSTORE_SSH:-cc}"
PREFIX="${CVLM_OSTORE_PREFIX:-clipvault/models/personal-lm}"
API="${CVLM_OSTORE_API:-http://127.0.0.1:8781}"
PUB="${CVLM_OSTORE_PUBLIC:-https://xyz69.top/ostore}"
CHUNK_MB="${CVLM_CHUNK_MB:-8}"
KEEPSAKE="${KEEPSAKE_HOME:-$HOME/Library/Application Support/Keepsake}"
BUNDLE_DIR="${CVLM_BUNDLE:-$KEEPSAKE/models/personal-lm}"
BIN_DIR="$KEEPSAKE/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
LORA_DIR="${CVLM_LORA_DIR:-$HERE/lora/adapters}"
TMP="$(mktemp -d /tmp/cvlm-sync.XXXXXX)"
PARTS_TMP="/tmp/cvlm-parts"          # pull 断点续传的分片缓存（跨运行保留）
trap 'rm -rf "$TMP"' EXIT

# ---- 传输后端：快路（公网直连）优先，失败自动回落 ssh 中继 ----
get_token() { ssh -o BatchMode=yes "$SSH_HOST" 'grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2'; }
TOKEN="$(get_token)"   # 只在内存，不落盘

pubapi() { # method path [file] —— 公网直连，path 含 /api/… 全路径；-f 使非 2xx 返回非零，超时放宽到 20 分钟
  local method="$1" path="$2" f="${3:-}"
  if [ -n "$f" ]; then
    curl -sf -m 1200 -X "$method" -H "Authorization: Bearer $TOKEN" \
      --data-binary @"$f" "$PUB$path"
  else
    curl -sf -m 1200 -X "$method" -H "Authorization: Bearer $TOKEN" "$PUB$path"
  fi
}
oapi() { # method path [extra curl args...] —— ssh 中继（兜底），-f 使非 2xx 返回非零
  local method="$1" path="$2"; shift 2
  ssh -o BatchMode=yes "$SSH_HOST" \
    "curl -sf -m 600 -X $method -H \"Authorization: Bearer $TOKEN\" $* \"$API$path\""
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
    mkdir -p "$TMP/bundle" "$TMP/bin" "$TMP/adapters"
    cp "$BUNDLE_DIR"/manifest.json "$BUNDLE_DIR"/config.json "$BUNDLE_DIR"/model.safetensors \
       "$BUNDLE_DIR"/tokenizer.json "$TMP/bundle/" 2>/dev/null || true
    [ -f "$BUNDLE_DIR/retrieval_lines.jsonl" ] && cp "$BUNDLE_DIR/retrieval_lines.jsonl" "$TMP/bundle/"
    if ls "$LORA_DIR/"*.safetensors >/dev/null 2>&1; then
      cp "$LORA_DIR/"*.safetensors "$TMP/adapters/"
    fi
    [ -f "$BIN_DIR/cv-lm" ] && cp "$BIN_DIR/cv-lm" "$TMP/bin/" && echo "[push] 含 cv-lm 二进制" \
      || echo "[push] 无本地 cv-lm 二进制，跳过"
    # 确定性打包：固定 mtime + gzip -n，同一 bundle 重跑产出相同字节 →
    # 分片可跨运行跳过/续传，parts.json 与分片永远自洽
    find "$TMP/bundle" "$TMP/adapters" "$TMP/bin" -type f -exec touch -t 200001010000 {} + 2>/dev/null || true
    tar -cf - -C "$TMP" bundle bin adapters 2>/dev/null | gzip -n > "$TMP/bundle.tar.gz" || \
      tar -cf - -C "$TMP" bundle adapters 2>/dev/null | gzip -n > "$TMP/bundle.tar.gz" || \
      tar -cf - -C "$TMP" bundle | gzip -n > "$TMP/bundle.tar.gz"
    SIZE=$(stat -f%z "$TMP/bundle.tar.gz")
    SHA=$(shasum -a 256 "$TMP/bundle.tar.gz" | cut -d' ' -f1)
    BDIR="$PREFIX/blocks-${SHA:0:8}"   # 分片目录按全量 sha 命名：跨版本隔离，旧分片永不混入
    echo "[push] bundle $((SIZE/1000000))MB sha256=${SHA}，切成 ${CHUNK_MB}MB 分片 → blocks-${SHA:0:8}/"
    mkdir -p "$TMP/parts" && split -b "${CHUNK_MB}m" -a 3 -d "$TMP/bundle.tar.gz" "$TMP/parts/p."
    PART_FILES=($(ls "$TMP/parts" | sort))
    NP=${#PART_FILES[@]}

    # 远端已有分片表（断点续传：跳过已存在且大小一致的分片）
    REMOTE_SIZES="$(pubapi GET "/api/list?path=$BDIR&limit=500" \
      | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  for e in d.get("entries",[]):
    print("%s %d" % (e["name"], e["size"]))
except Exception: pass' 2>/dev/null || true)"

    i=0
    for pf in "${PART_FILES[@]}"; do
      i=$((i+1))
      PSZ=$(stat -f%z "$TMP/parts/$pf")
      if printf '%s\n' "$REMOTE_SIZES" | grep -q "^$pf $PSZ\$"; then
        echo "[push] [$i/$NP] $pf 已在远端（大小一致），跳过"
        continue
      fi
      echo "[push] [$i/$NP] 上传 $pf ($((PSZ/1000000))MB)…"
      ok=0
      for attempt in 1 2 3; do
        if pubapi PUT "/api/files/$BDIR/$pf" "$TMP/parts/$pf" >/dev/null 2>&1; then ok=1; break; fi
        echo "[push]   公网第 $attempt 次失败，重试/回落 ssh 中继"
        # 兜底：stdin 管道（文件在 mac 本地，不能 @ 路径传给远端 curl）
        ssh -o BatchMode=yes "$SSH_HOST" \
          "curl -sf -m 600 -X PUT -H 'Authorization: Bearer $TOKEN' --data-binary @- -o /dev/null '$API/api/files/$PREFIX/parts/$pf'" \
          < "$TMP/parts/$pf" && { ok=1; break; }
        sleep 2
      done
      [ "$ok" = 1 ] || { echo "[push] $pf 上传失败（3 次），重跑即可续传"; exit 1; }
      # PUT 200 ≠ 到齐（中断连接可能产生 200+0 字节对象）：
      # 回读 size；不符 → DELETE 坏对象 → 重 PUT → 再校验（3 轮内自愈）
      RSZ=0
      for c in 1 2 3; do
        for q in 1 2 3 4; do
          RSZ=$(pubapi GET "/api/list?path=$BDIR&limit=500" | python3 -c \
            "import json,sys;[print(e['size']) for e in json.load(sys.stdin)['entries'] if e['name']=='$pf']" 2>/dev/null || echo 0)
          [ "$RSZ" = "$PSZ" ] && break
          sleep 3
        done
        [ "$RSZ" = "$PSZ" ] && break
        echo "[push]   远端 $pf=$RSZ ≠ ${PSZ}（坏的 0 字节对象？）→ DELETE 重传（第 $c 轮）"
        pubapi DELETE "/api/files/$BDIR/$pf" >/dev/null 2>&1 || true
        pubapi PUT "/api/files/$BDIR/$pf" "$TMP/parts/$pf" >/dev/null 2>&1 || true
      done
      [ "$RSZ" = "$PSZ" ] || { echo "[push] 远端 $pf 大小 ${RSZ} ≠ 本地 ${PSZ}，重跑即可续传"; exit 1; }
    done

    # 分片 sha256 清单 + 全量元数据（原子性：整份 stdin 一次 PUT）
    BDIR_NAME="blocks-${SHA:0:8}" python3 - "$TMP/parts" "$VER" "$SHA" "$SIZE" "$CHUNK_MB" > "$TMP/parts.json" <<'PY'
import hashlib, json, os, sys
parts_dir, ver, sha, size, chunk = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
entries = []
for f in sorted(os.listdir(parts_dir)):
    p = os.path.join(parts_dir, f)
    h = hashlib.sha256()
    with open(p, 'rb') as fh:
        for b in iter(lambda: fh.read(1 << 20), b''):
            h.update(b)
    entries.append({"name": f, "bytes": os.path.getsize(p), "sha256": h.hexdigest()})
print(json.dumps({"mode": "parts", "version": ver, "sha256": sha, "bytes": size,
                  "dir": os.environ.get("BDIR_NAME", ""),
                  "chunk_mb": chunk, "parts": entries}, ensure_ascii=False))
PY
    pubapi PUT "/api/files/$PREFIX/bundle.parts.json" "$TMP/parts.json" >/dev/null \
      || oapi PUT "/api/files/$PREFIX/bundle.parts.json" --data-binary @"$TMP/parts.json" -o /dev/null
    python3 -c "import json,sys;d=json.load(open('$TMP/parts.json'));print(json.dumps({'version':d['version'],'sha256':d['sha256'],'bytes':d['bytes'],'pushed_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)','mode':'parts'}))" > "$TMP/LATEST.json"
    pubapi PUT "/api/files/$PREFIX/LATEST.json" "$TMP/LATEST.json" >/dev/null \
      || oapi PUT "/api/files/$PREFIX/LATEST.json" --data-binary @"$TMP/LATEST.json" -o /dev/null
    # 清掉旧的单文件对象（v2 已用分片清单，留着误导且占 gdrive 空间）
    pubapi DELETE "/api/files/$PREFIX/bundle.tar.gz" >/dev/null 2>&1 || oapi DELETE "/api/files/$PREFIX/bundle.tar.gz" >/dev/null 2>&1 || true
    # 清掉旧版 legacy 分片目录（parts/），防 gdrive 空间浪费
    LEGACY="$(pubapi GET "/api/list?path=$PREFIX/parts&limit=500" 2>/dev/null | python3 -c 'import json,sys
try:
  for e in json.load(sys.stdin).get("entries",[]): print(e["name"])
except Exception: pass' 2>/dev/null || true)"
    if [ -n "$LEGACY" ]; then
      echo "[push] 清理 legacy parts/ …"
      while read -r n; do [ -n "$n" ] && pubapi DELETE "/api/files/$PREFIX/parts/$n" >/dev/null 2>&1 || true; done <<< "$LEGACY"
    fi
    echo "[push] 完成：$VER ($SHA, $NP 分片)；pull 端中断重跑只补缺片"
    ;;

  pull)
    LATEST=$(pubapi GET "/api/files/$PREFIX/LATEST.json" || oapi GET "/api/files/$PREFIX/LATEST.json")
    VER=$(printf '%s' "$LATEST" | python3 -c "import json,sys;print(json.load(sys.stdin)['version'])")
    CUR=$(local_version)
    if [ "$CUR" = "$VER" ]; then echo "[pull] 已是最新 ${VER}，无需更新"; exit 0; fi
    PARTS_JSON="$(pubapi GET "/api/files/$PREFIX/bundle.parts.json" 2>/dev/null || true)"
    if [ -n "$PARTS_JSON" ] && printf '%s' "$PARTS_JSON" | python3 -c "import json,sys;json.load(sys.stdin)" >/dev/null 2>&1; then
      eval "$(printf '%s' "$PARTS_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print('FULL_SHA=%s'%d['sha256']);print('RDIR=%s'%d.get('dir',''))")"
      [ -n "$RDIR" ] || RDIR="parts"
      PDIR="$PARTS_TMP/$RDIR"; mkdir -p "$PDIR"
      echo "[pull] $CUR → ${VER}（分片模式 ${RDIR}，断点续传）"
      printf '%s' "$PARTS_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d['parts']: print(p['name'], p['bytes'], p['sha256'])" > "$TMP/partlist"
      while read -r name b sha; do
        f="$PDIR/$name"
        if [ -f "$f" ] && [ "$(stat -f%z "$f")" = "$b" ] \
           && [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ]; then
          echo "[pull]   $name 本地已有（校验过），跳过"
        else
          rm -f "$f"
          echo "[pull]   下载 $name ($((b/1000000))MB)…"
          for attempt in 1 2; do
            if [ "$attempt" = 1 ]; then
              pubapi GET "/api/files/$PREFIX/$RDIR/$name" > "$f" 2>/dev/null || true
            else
              oapi GET "/api/files/$PREFIX/$RDIR/$name" > "$f"
            fi
            [ "$(stat -f%z "$f")" = "$b" ] && [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ] && break
            [ "$attempt" = 2 ] && { echo "分片 $name 校验失败"; exit 1; }
          done
        fi
      done < "$TMP/partlist"
      : > "$TMP/bundle.tar.gz"; while read -r name b sha; do cat "$PDIR/$name" >> "$TMP/bundle.tar.gz"; done < "$TMP/partlist"
    else
      # 旧版单文件 bundle
      SHA=$(printf '%s' "$LATEST" | python3 -c "import json,sys;print(json.load(sys.stdin)['sha256'])")
      echo "[pull] $CUR → ${VER}（单文件模式）下载中…"
      pubapi GET "/api/files/$PREFIX/bundle.tar.gz" > "$TMP/bundle.tar.gz" \
        || oapi GET "/api/files/$PREFIX/bundle.tar.gz" > "$TMP/bundle.tar.gz"
      GOT=$(shasum -a 256 "$TMP/bundle.tar.gz" | cut -d' ' -f1)
      [ "$GOT" = "$SHA" ] || { echo "sha256 不匹配：期望 $SHA 实得 $GOT"; exit 1; }
      FULL_SHA="$SHA"
    fi
    GOT=$(shasum -a 256 "$TMP/bundle.tar.gz" | cut -d' ' -f1)
    [ "$GOT" = "$FULL_SHA" ] || { echo "全量 sha256 不匹配：期望 $FULL_SHA 实得 $GOT"; exit 1; }
    mkdir -p "$BUNDLE_DIR" "$BIN_DIR" "$LORA_DIR"
    tar -xzf "$TMP/bundle.tar.gz" -C "$TMP"
    cp "$TMP/bundle"/* "$BUNDLE_DIR/"
    if [ -d "$TMP/adapters" ] && ls "$TMP/adapters/"*.safetensors >/dev/null 2>&1; then
      cp "$TMP/adapters/"*.safetensors "$LORA_DIR/"
    fi
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
    LATEST=$(pubapi GET "/api/files/$PREFIX/LATEST.json" 2>/dev/null || oapi GET "/api/files/$PREFIX/LATEST.json")
    printf '%s' "$LATEST" | python3 -c "import json,sys;d=json.load(sys.stdin);print('ostore:', d['version'], d.get('bytes',0),'B', d.get('pushed_at',''), d.get('mode','single'))" 2>/dev/null \
      || echo "ostore: 无（从未 push）"
    ;;

  *)
    echo "用法: sync_model.sh push|pull|status"; exit 1 ;;
esac
