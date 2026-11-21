#!/usr/bin/env bash
# personal-lm D5: 增量迭代闭环（一键）。
#
#   ./iterate.sh              # 增量导出 → warm start 续训 → eval → 导出 bundle → 热加载生效
#   ./iterate.sh --full       # 全量重建语料从头训（重置 watermark）
#
# 闭环：内容增长 → exporter watermark → 续训 → eval → bundle → cv-lm 热加载（无需重启）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/.venv/bin/python"
FULL="${1:-}"

echo "── 1/4 导出语料"
"$PY" "$HERE/data/export_clipflow.py" $([ "$FULL" = "--full" ] && echo "" || echo "--incremental")
"$PY" "$HERE/data/export_nmem.py" $([ "$FULL" = "--full" ] && echo "" || echo "--incremental")
"$PY" "$HERE/data/build_corpus.py" >/dev/null

echo "── 2/4 语料 → tokens"
"$PY" "$HERE/train/tokenizer.py" encode --corpus "$HERE/corpus/all.txt" --out "$HERE/corpus/tokens.bin"

echo "── 3/4 续训（warm start 最新 checkpoint）"
"$PY" "$HERE/train/train.py" --resume-latest --steps "$([ -n "$FULL" ] && echo 3000 || echo 1500)"

echo "── 4/4 eval + 导出 bundle（→ CLIPVAULT_HOME/models/personal-lm，cv-lm 自动热加载）"
"$PY" "$HERE/eval/perplexity.py"
"$PY" "$HERE/train/export_bundle.py"

# live web 资产同步（ClipVaultServer 从 Keepsake/web 服务）
DEST="$HOME/Library/Application Support/Keepsake/web/assets/notes-editor"
if [ -d "$DEST" ]; then
  cp "$HERE/../web/assets/notes-editor/entry.js"      "$HERE/../web/assets/notes-editor/notes-editor.js"      "$HERE/../web/assets/notes-editor/notes-editor.css" "$DEST/" 2>/dev/null || true
fi

echo "✅ 迭代完成：新 bundle 已热加载，无需重启 cv-lm / ClipVaultServer"
