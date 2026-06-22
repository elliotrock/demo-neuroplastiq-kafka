#!/usr/bin/env bash
set -euo pipefail

: "${ROLE_ARN:?Set ROLE_ARN to the deploy role ARN before running}"
: "${AWS_REGION:=ap-southeast-2}"

CREDS="$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name local-cli)"

export AWS_ACCESS_KEY_ID
AWS_ACCESS_KEY_ID="$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)"

export AWS_SECRET_ACCESS_KEY
AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)"

export AWS_SESSION_TOKEN
AWS_SESSION_TOKEN="$(echo "$CREDS" | jq -r .Credentials.SessionToken)"

export AWS_REGION
