#!/usr/bin/env bash
# Kaggle 无人值守 GPU 训练驱动：kaggle_run.sh gpt|qwen|status
# 前置：~/.kaggle/kaggle.json（2 分钟：kaggle.com → Settings → API → Create New Token）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CMD="${1:-status}"
KAGGLE=/kaggle  # 占位（防未安装时误执行）

command -v kaggle >/dev/null || pip3 install -q kaggle 2>/dev/null || true
command -v kaggle >/dev/null || { echo "pip install kaggle 失败"; exit 1; }
[ -f "$HOME/.kaggle/kaggle.json" ] || { echo "缺 ~/.kaggle/kaggle.json（kaggle.com → Settings → API → Create New Token）"; exit 1; }
chmod 600 "$HOME/.kaggle/kaggle.json"

DS_NAME="clipvault-personal-lm-data"
KERNEL_PREFIX=$(python3 -c "import json;print(json.load(open('$HOME/.kaggle/kaggle.json'))['username'])")

case "$CMD" in
  gpt|qwen)
    # 1) 数据集（cloud_bundle.tar.gz → private dataset）
    TMP=$(mktemp -d)
    if ! kaggle datasets status "$KERNEL_PREFIX/$DS_NAME" >/dev/null 2>&1; then
      mkdir -p "$TMP/$DS_NAME"
      ssh -o BatchMode=yes cc "T=\$(grep OSTORE_TOKEN /etc/ostore.env | cut -d= -f2);
        curl -s -m 300 -H \"Authorization: Bearer \$T\" \
          'http://127.0.0.1:8781/api/files/clipvault/models/personal-lm/cloud/cloud_bundle.tar.gz'" \
        > "$TMP/$DS_NAME/cloud_bundle.tar.gz"
      cat > "$TMP/$DS_NAME/dataset-metadata.json" <<EOF
{ "title": "$DS_NAME", "id": "$KERNEL_PREFIX/$DS_NAME", "licenses": [{"name": "other"}] }
EOF
      kaggle datasets create -p "$TMP/$DS_NAME" -r tar.gz --dir-mode zip
      echo "dataset 创建中（处理 zip 需 1-2 分钟）…"; sleep 120
    fi
    rm -rf "$TMP"
    # 2) 推内核
    if [ "$CMD" = gpt ]; then
      cp "$HERE/gpt_kernel.py" "$HERE/gpt_kernel-metadata.json" "$TMP" 2>/dev/null || true
      MET="$HERE/gpt_kernel-metadata.json"
      cp "$HERE/gpt_kernel.py" "$TMP/gpt_kernel.py"
    else
      MET="$HERE/qwen_kernel-metadata.json"
      cp "$HERE/qwen_kernel.py" "$TMP/qwen_kernel.py"
    fi
    kaggle kernels push -p "$TMP" -m "$MET" >/dev/null 2>&1 || kaggle kernels push -p "$TMP" -m "$MET"
    echo "内核已推送，开始排队训练。监控：./kaggle_run.sh status"
    kaggle kernels status "$KERNEL_PREFIX/$( [ "$CMD" = gpt ] && echo personal-gpt-train || echo qwen-lora-train )" || true
    ;;
  status)
    for k in personal-gpt-train qwen-lora-train; do
      echo "== $k =="; kaggle kernels status "$KERNEL_PREFIX/$k" || true
    done
    ;;
  pull)
    K="${2:-personal-gpt-train}"
    mkdir -p "$HERE/out/$K"
    kaggle kernels output "$KERNEL_PREFIX/$K" -p "$HERE/out/$K"
    echo "产物 → $HERE/out/$K"
    ;;
  *) echo "用法: kaggle_run.sh gpt|qwen|status|pull [kernel]" ;;
esac
