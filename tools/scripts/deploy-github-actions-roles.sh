#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${STACK_NAME:-neuro-github-actions-roles}"
REGION="${AWS_REGION:-ap-southeast-2}"
OIDC_PROVIDER_ARN="${OIDC_PROVIDER_ARN:-}"
CREATE_DEV_ROLE="${CREATE_DEV_ROLE:-false}"
CREATE_STAGING_ROLE="${CREATE_STAGING_ROLE:-true}"
CREATE_PROD_ROLE="${CREATE_PROD_ROLE:-true}"

if [ -z "$OIDC_PROVIDER_ARN" ]; then
  echo "[error] OIDC_PROVIDER_ARN is required (arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com)" >&2
  exit 1
fi

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file infra/cloudformation/github-actions-roles.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    OidcProviderArn="$OIDC_PROVIDER_ARN" \
    CreateDevRole="$CREATE_DEV_ROLE" \
    CreateStagingRole="$CREATE_STAGING_ROLE" \
    CreateProdRole="$CREATE_PROD_ROLE" \
  --region "$REGION"

echo "[info] deployed stack $STACK_NAME in $REGION"
