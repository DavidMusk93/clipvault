#!/usr/bin/env bash
set -euo pipefail

echo "[ClipFlow] 准备本地部署 PaddleOCR（Python 虚拟环境）"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${PROJECT_DIR}/tools/paddleocr_venv"
WRAP_DIR="${PROJECT_DIR}/bin"

# 解析可选参数：--proxy=http://host:port 与可选的 Index 镜像
PIP_PROXY="${PIP_PROXY:-}"
PIP_INDEX_URL="${PIP_INDEX_URL:-}"
for arg in "$@"; do
  case "$arg" in
    --proxy=*) PIP_PROXY="${arg#*=}" ;;
    --index=*) PIP_INDEX_URL="${arg#*=}" ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ 未检测到 python3，请先安装（例如：brew install python@3）"
  exit 1
fi

python3 -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"

# 如果指定了代理或环境已设置代理，则写入 venv 级 pip.conf，确保后续安装均走代理
mkdir -p "${VENV_DIR}"
PIPCONF="${VENV_DIR}/pip.conf"
{
  echo "[global]"
  echo "timeout = 120"
  if [ -n "${PIP_PROXY}" ]; then
    echo "proxy = ${PIP_PROXY}"
    export http_proxy="${PIP_PROXY}"; export https_proxy="${PIP_PROXY}"
    echo "[ClipFlow] 使用代理：${PIP_PROXY}"
  elif [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ]; then
    echo "# 继承系统代理 http_proxy/https_proxy"
  fi
  if [ -n "${PIP_INDEX_URL}" ]; then
    echo "index-url = ${PIP_INDEX_URL}"
  fi
} > "${PIPCONF}"

python -m pip install --upgrade pip wheel setuptools

echo "[ClipFlow] 安装 paddlepaddle 与 paddleocr（可能较慢）"
python -m pip install "paddlepaddle>=2.5" "paddleocr>=2.7"

mkdir -p "${WRAP_DIR}"
cat > "${WRAP_DIR}/paddleocr_cli" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/../tools/paddleocr_venv/bin/activate"
exec python3 -m paddleocr "$@"
EOF
chmod +x "${WRAP_DIR}/paddleocr_cli"

echo "[ClipFlow] 已创建包装命令：${WRAP_DIR}/paddleocr_cli"
echo "[ClipFlow] 你可以在应用内通过设置键 clipflow.paddle.path 配置该路径："
echo "defaults write com.clipflow.app clipflow.paddle.path '${WRAP_DIR}/paddleocr_cli'"
