#!/usr/bin/env bash
set -euo pipefail

ROLE_NAME="${1:-github-actions-deploy-dev}"
POLICY_NAME="${2:-neuro-apigateway}"
POLICY_PATH="infra/iam/github-actions-apigateway-policy.json"

if [ ! -f "$POLICY_PATH" ]; then
  echo "[error] policy file not found: $POLICY_PATH" >&2
  exit 1
fi

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://${POLICY_PATH}"

echo "[info] attached inline policy ${POLICY_NAME} to role ${ROLE_NAME}"
