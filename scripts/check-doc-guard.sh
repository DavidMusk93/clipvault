#!/bin/bash
# check-doc-guard.sh — flowkit:doc_guard 文档格式门禁。
# 规则真源：$FLOWKIT_HOME/scripts/validate_docs.py（版式/kebab/日期/front-matter/链接）。
# FLOWKIT_HOME 默认 ~/Documents/01_Projects/flowkit；缺失 = 门禁失败（不许静默跳过）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOWKIT_HOME="${FLOWKIT_HOME:-$HOME/Documents/01_Projects/flowkit}"
VALIDATOR="$FLOWKIT_HOME/scripts/validate_docs.py"
if [ ! -f "$VALIDATOR" ]; then
  echo "[check-doc-guard] FAIL: flowkit validator not found at $VALIDATOR" >&2
  echo "[check-doc-guard] set FLOWKIT_HOME or install the flowkit checkout" >&2
  exit 1
fi
python3 "$VALIDATOR" --root "$ROOT"
echo "[check-doc-guard] OK"
