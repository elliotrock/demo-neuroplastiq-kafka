#!/usr/bin/env bash
set -euo pipefail

BUCKET="${1:-}"
AWS_REGION="${2:-}"
PREFIX="${3:-connectors}"
CONNECTOR_SELECTOR="${4:---all}"

if [[ -z "$BUCKET" || -z "$AWS_REGION" ]]; then
  echo "Usage: $0 <bucket> <aws-region> [prefix] [connector|--all]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONNECTORS_DIR="${ROOT_DIR}/confluent/connectors"

if [[ ! -d "$CONNECTORS_DIR" ]]; then
  echo "Connectors directory not found: ${CONNECTORS_DIR}"
  exit 1
fi

shopt -s nullglob
artifacts=(
  "${CONNECTORS_DIR}"/*/*.zip
)
shopt -u nullglob

if [[ ${#artifacts[@]} -eq 0 ]]; then
  echo "No connector ZIP artifacts found under ${CONNECTORS_DIR}."
  exit 1
fi

selected_artifacts=()
for artifact in "${artifacts[@]}"; do
  connector_name="$(basename "$(dirname "${artifact}")")"
  if [[ "${CONNECTOR_SELECTOR}" == "--all" || "${CONNECTOR_SELECTOR}" == "all" || "${connector_name}" == "${CONNECTOR_SELECTOR}" ]]; then
    selected_artifacts+=("${artifact}")
  fi
done

if [[ ${#selected_artifacts[@]} -eq 0 ]]; then
  if [[ "${CONNECTOR_SELECTOR}" == "--all" || "${CONNECTOR_SELECTOR}" == "all" ]]; then
    echo "No connector ZIP artifacts found under ${CONNECTORS_DIR}."
  else
    echo "No ZIP artifacts found for connector '${CONNECTOR_SELECTOR}' under ${CONNECTORS_DIR}."
  fi
  exit 1
fi

for artifact in "${selected_artifacts[@]}"; do
  connector_name="$(basename "$(dirname "${artifact}")")"
  file_name="$(basename "${artifact}")"
  s3_key="${PREFIX}/${connector_name}/${file_name}"

  echo "Uploading ${artifact} -> s3://${BUCKET}/${s3_key}"
  aws s3 cp "${artifact}" "s3://${BUCKET}/${s3_key}" --region "${AWS_REGION}"
done
