#!/usr/bin/env bash
set -euo pipefail

# ClipFlow 开发脚本
# 新增 --watch 模式：监听 Swift 源码，自动编译并重启应用

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
SCHEME="ClipFlow"
CONFIG="Debug"
DEST="platform=macOS"
WATCH=0

for arg in "$@"; do
  case "$arg" in
    --watch) WATCH=1 ;;
    --scheme=*) SCHEME="${arg#*=}" ;;
    --config=*) CONFIG="${arg#*=}" ;;
    --destination=*) DEST="${arg#*=}" ;;
    -h|--help)
      cat <<EOF
用法: ./run.sh [--watch] [--scheme=ClipFlow] [--config=Debug] [--destination='platform=macOS']
  --watch         监听源码变更，自动编译并重启应用
  --scheme        指定 Xcode Scheme（默认 ClipFlow）
  --config        指定构建配置（默认 Debug）
  --destination   指定目标（默认 platform=macOS）
EOF
      exit 0
      ;;
  esac
done

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "❌ 未检测到 xcodebuild，请先安装 Xcode 或命令行工具：xcode-select --install"
  exit 1
fi

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/ClipFlow.app"

build() {
  echo "\n▶︎ 编译 ${SCHEME} (${CONFIG}) …"
  xcodebuild -project "${PROJECT_DIR}/ClipFlow.xcodeproj" \
            -scheme "${SCHEME}" \
            -configuration "${CONFIG}" \
            -destination "${DEST}" \
            -derivedDataPath "${DERIVED_DATA}" \
            build >/dev/null
  echo "✅ 构建成功"
}

run_app() {
  # 关闭已运行实例，再启动新的
  pkill -x ClipFlow 2>/dev/null || true
  sleep 0.3
  if [ -d "${APP_PATH}" ]; then
    echo "🚀 启动应用: ${APP_PATH}"
    open "${APP_PATH}"
  else
    echo "❌ 未找到可执行应用：${APP_PATH}"
    exit 1
  fi
}

build_and_run() {
  if build; then
    run_app
  fi
}

if [ "${WATCH}" -eq 1 ]; then
  echo "👀 进入 Watch 模式（保存即自动重启）"
  echo "    Scheme: ${SCHEME} | Config: ${CONFIG} | Dest: ${DEST}"
  build_and_run
  if command -v fswatch >/dev/null 2>&1; then
    fswatch -0 -r "${PROJECT_DIR}/ClipFlow" "${PROJECT_DIR}/ClipFlow.xcodeproj" \
      | while IFS= read -r -d '' _; do build_and_run; done
  elif command -v entr >/dev/null 2>&1; then
    find "${PROJECT_DIR}/ClipFlow" -type f \( -name '*.swift' -o -name '*.xcconfig' \) \
      | entr -n bash -lc "$(declare -f build_and_run); build_and_run"
  else
    echo "⚠️ 未检测到 fswatch 或 entr，使用简易轮询（每 2 秒）"
    LAST_SUM=""
    while true; do
      CURR_SUM=$(find "${PROJECT_DIR}/ClipFlow" -type f -name '*.swift' -print0 | xargs -0 shasum 2>/dev/null | shasum | awk '{print $1}') || true
      if [ "${CURR_SUM}" != "${LAST_SUM}" ]; then
        LAST_SUM="${CURR_SUM}"
        build_and_run
      fi
      sleep 2
    done
  fi
else
  build_and_run
fi
