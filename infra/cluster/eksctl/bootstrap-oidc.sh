#!/usr/bin/env bash
set -e

CLUSTER_NAME="neuro-dev"
REGION="ap-southeast-2"

echo "🔧 Checking OIDC provider for cluster: $CLUSTER_NAME"

OIDC_PRESENT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

if [[ "$OIDC_PRESENT" == "None" ]]; then
  echo "🚨 No OIDC provider found, attaching…"
  eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --approve
else
  echo "✅ OIDC provider already set: $OIDC_PRESENT"
fi
