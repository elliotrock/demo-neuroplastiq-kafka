
#!/usr/bin/env bash
set -euo pipefail

ROLE_ARN="arn:aws:iam::838869291259:role/github-actions-deploy-dev"

CREDS=$(aws sts assume-role --role-arn arn:aws:iam::838869291259:role/cli-admin --role-session-name local-cli)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

aws sts get-caller-identity