#!/usr/bin/env bash
set -euo pipefail

# Update PRINCIPAL_ARN to the role/user you want to grant cluster admin access.
PRINCIPAL_ARN="arn:aws:iam::755267562381:root"

aws eks create-access-entry --cluster-name neuro-dev --principal-arn "$PRINCIPAL_ARN" --type STANDARD --region ap-southeast-2 || true
aws eks associate-access-policy --cluster-name neuro-dev \
  --principal-arn "$PRINCIPAL_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region ap-southeast-2
