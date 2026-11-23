#!/usr/bin/env bash
# colab_cli_train.sh — 用 google-colab-cli（官方 googlecolab/google-colab-cli）在
# 消费版 Colab Pro 算力上驱动 personal-lm 训练。取代"消费版 Colab 无执行 API"的旧结论。
#
#   首次：终端里跑 `colab new -s ptrain --gpu A100`，按提示打开 URL、粘贴授权码
#         （oauth2 copy-paste 流程，token 进 OS keyring，一次即可）。
#   之后全部免人工：
#     colab_cli_train.sh start   [steps] [layers] [d_model] [heads]   # 建会话+传料+启动训练
#     colab_cli_train.sh poll                                         # 看训练日志尾部
#     colab_cli_train.sh download                                    # VM 上 export bundle → 拉回本机
#     colab_cli_train.sh push                                        # download 后推 ostore（供 mac-home pull）
#     colab_cli_train.sh status                                       # 会话/算力余额
#     colab_cli_train.sh stop                                         # 释放 VM
#
# 隐私：corpus/bundle 只走 Colab VM 和本机/ostore，绝不进 git/公共 Hub（PRIVACY.md）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLM="$(cd "$HERE/.." && pwd)"
SESSION="${CVLM_COLAB_SESSION:-ptrain}"
GPU="${CVLM_COLAB_GPU:-A100}"
STEPS="${1:-20000}"
LAYERS="${2:-12}"
DMODEL="${3:-768}"
HEADS="${4:-12}"
VM="/content"
EX () { echo "$2" | colab exec -s "$SESSION"; }   # EX <label> <code>

has_session() { colab sessions 2>/dev/null | grep -q "$SESSION"; }

_ensure_session() {
  if has_session; then echo "[colab] 复用会话 $SESSION"; colab status -s "$SESSION" || true
  else
    echo "[colab] 新建 $GPU 会话 $SESSION（首次会要求 OAuth 授权）"
    colab new -s "$SESSION" --gpu "$GPU"
  fi
}

_upload_payload() {
  echo "[colab] 安装依赖（uv）…"
  colab install -s "$SESSION" torch numpy safetensors
  EX prepare "import os
os.makedirs('$VM/train', exist_ok=True); os.makedirs('$VM/corpus', exist_ok=True)
os.makedirs('$VM/checkpoints', exist_ok=True); os.makedirs('$VM/exports', exist_ok=True)
print('dirs ok')"
  echo "[colab] 上传训练代码 + 语料（tokens_weighted 33MB）…"
  colab upload -s "$SESSION" "$PLM/train/model.py"       "$VM/train/model.py"
  colab upload -s "$SESSION" "$PLM/train/tokenizer.py"   "$VM/train/tokenizer.py"
  colab upload -s "$SESSION" "$PLM/train/train.py"       "$VM/train/train.py"
  colab upload -s "$SESSION" "$PLM/train/export_bundle.py" "$VM/train/export_bundle.py"
  colab upload -s "$SESSION" "$PLM/corpus/tokens_weighted.bin" "$VM/corpus/tokens_weighted.bin"
  colab upload -s "$SESSION" "$PLM/corpus/tokenizer.json"      "$VM/corpus/tokenizer.json"
}

case "${1:-start}" in
  start)
    _ensure_session
    _upload_payload
    echo "[colab] 后台启动训练：steps=$STEPS layers=$LAYERS d=$DMODEL heads=$HEADS"
    EX launch "import subprocess
cmd=['python','$VM/train/train.py','--steps','$STEPS','--device','cuda',
     '--layers','$LAYERS','--d-model','$DMODEL','--heads','$HEADS',
     '--tokens','$VM/corpus/tokens_weighted.bin','--eval-every','500','--ckpt-every','500']
open('$VM/train.out','w').close()
subprocess.Popen(cmd, cwd='$VM', stdout=open('$VM/train.out','w'),
                 stderr=subprocess.STDOUT)
print('launched')"
    echo "[colab] 已启动。查看进度：$0 poll"
    ;;

  poll)
    EX poll "print(open('$VM/train.out').read()[-2500:] if __import__('os').path.exists('$VM/train.out') else 'no log yet')"
    ;;

  download)
    echo "[colab] VM 上导出 bundle…"
    EX export "import subprocess; print(subprocess.run(['python','$VM/train/export_bundle.py'],
             cwd='$VM', capture_output=True, text=True).stdout[-800:])"
    VER=$(EX export "import os,json;d='$VM/exports';vs=sorted(os.listdir(d));
print(vs[-1] if vs else '')" | tail -1)
    [ -n "$VER" ] || { echo "export 目录为空"; exit 1; }
    echo "[colab] 打包下载 $VER …"
    EX tar "import subprocess; subprocess.run(['tar','-czf','$VM/bundle.tar.gz','-C','$VM/exports','$VER'],cwd='$VM'); print('tar ok')"
    mkdir -p "$PLM/exports"
    colab download -s "$SESSION" "$VM/bundle.tar.gz" "$PLM/exports/bundle.tar.gz"
    tar -xzf "$PLM/exports/bundle.tar.gz" -C "$PLM/exports"
    rm -f "$PLM/exports/bundle.tar.gz"
    echo "[download] $PLM/exports/$VER/"
    echo "下一步部署：cp -R \"$PLM/exports/$VER/\" \"$HOME/Library/Application Support/Keepsake/models/personal-lm/\"（cv-lm 热加载）"
    ;;

  push)
    VER=$(ls -1 "$PLM/exports" | sort | tail -1)
    [ -n "$VER" ] || { echo "本机 exports 为空，先 download"; exit 1; }
    echo "[push] $VER → ostore"
    BUNDLE_DIR="$PLM/exports/$VER" bash -c 'KEEPSAKE=/tmp/cvlm-push-fake
      mkdir -p "$KEEPSAKE/models"; rm -rf "$KEEPSAKE/models/personal-lm"
      cp -R "$BUNDLE_DIR" "$KEEPSAKE/models/personal-lm"
      KEEPSAKE_HOME="$KEEPSAKE" '"$PLM"'/sync_model.sh push'
    echo "[push] 完成：mac 任意机器 `sync_model.sh pull` 即可"
    ;;

  status)
    colab sessions || true
    colab usage || true
    ;;

  stop)
    colab stop -s "$SESSION" || true
    echo "[colab] 会话已释放"
    ;;

  *) echo "用法: $0 start|poll|download|push|status|stop"; exit 1 ;;
esac
