#!/usr/bin/env bash
# Colab Enterprise 一次性 setup（之后的训练由 gcloud colab executions 全程 CLI 驱动）。
# 需要浏览器交互的点：① gcloud init 登录 ② 创建 billing 账号绑卡（$300 试用金）
# 用法: ./gcloud_setup.sh
set -euo pipefail
export PATH=/opt/homebrew/share/google-cloud-sdk/bin:$PATH

PROJECT="${1:-personal-lm-train}"
REGION="${2:-us-central1}"
BUCKET="${3:-personal-lm-train-$RANDOM}"

echo "── 1/6 登录（浏览器会打开，用你的 Google 账号）"
gcloud auth login 2>/dev/null || gcloud init

echo "── 2/6 建项目 $PROJECT"
gcloud projects create "$PROJECT" --name="personal-lm" 2>/dev/null || echo "(项目可能已存在)"
gcloud config set project "$PROJECT"

echo "── 3/6 绑定 billing（⚠️ 浏览器步骤：Console → Billing → 新建账单账号绑卡，获得 \$300 试用金）"
echo "   打开: https://console.cloud.google.com/billing/create?project=$PROJECT"
read -p "billing 账号 ID（形如 0X0X0X-0X0X0X-0X0X0X，Console Billing 页可见）: " BILLING
gcloud billing projects link "$PROJECT" --billing-account="$BILLING"

echo "── 4/6 启用 API（Colab Enterprise + Compute + GCS）"
gcloud services enable colab.googleapis.com compute.googleapis.com storage.googleapis.com aiplatform.googleapis.com

echo "── 5/6 建 GCS bucket + 上传训练 notebook"
gcloud storage buckets create "gs://$BUCKET" --location="$REGION" 2>/dev/null || true
gcloud storage cp "$(dirname "$0")/personal_gpt_cloud_enterprise.py" "gs://$BUCKET/notebooks/"

echo "── 6/6 建 GPU runtime template（L4：性价比最高；A100 改 --accelerator-core-count）"
REGION_FULL="$REGION"
gcloud colab runtime-templates create "$PROJECT" \
  --display-name="personal-lm-l4" \
  --location="$REGION_FULL" \
  --machine-type="g2-standard-8" \
  --accelerator-type="NVIDIA_L4" \
  --accelerator-core-count=1 \
  --network="projects/$PROJECT/global/networks/default" 2>/dev/null \
  || echo "（若网络/default 不存在：先 gcloud compute networks create default --subnet-mode=auto）"

echo ""
echo "✅ setup 完成。之后的训练（我接管）："
echo "   gcloud colab executions create --project=$PROJECT --location=$REGION \\"
echo "     --display-name=train-v1 --notebook=gs://$BUCKET/notebooks/personal_gpt_cloud_enterprise.py \\"
echo "     --runtime-template=personal-lm-l4"
echo "   gcloud colab executions list --project=$PROJECT --location=$REGION"
echo "   gcloud storage cp -r gs://$BUCKET/exports/ ./exports/"
