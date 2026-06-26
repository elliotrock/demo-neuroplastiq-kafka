
#!/usr/bin/env bash
set -euo pipefail

ROLE_ARN="${ROLE_ARN:-arn:aws:iam::755267562381:role/github-actions-deploy-staging}"

CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name local-cli)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

aws sts get-caller-identity
