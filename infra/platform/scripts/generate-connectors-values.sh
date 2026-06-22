#!/usr/bin/env bash
set -euo pipefail

BUCKET="${1:-}"
AWS_REGION="${2:-}"
OUTPUT_PATH="${3:-}"
PREFIX="${4:-connectors}"
CONNECTOR_SELECTOR="${5:---all}"

if [[ -z "$BUCKET" || -z "$AWS_REGION" || -z "$OUTPUT_PATH" ]]; then
  echo "Usage: $0 <bucket> <aws-region> <output-path> [prefix] [connector|--all]"
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
  echo "No connector ZIP artifacts found under ${CONNECTORS_DIR}." >&2
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
  echo "No ZIP artifacts found for connector '${CONNECTOR_SELECTOR}' under ${CONNECTORS_DIR}." >&2
  exit 1
fi

checksum_for() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | awk '{print $1}'
    return 0
  fi
  return 1
}

{
  echo "connect:"
  echo "  build:"
  echo "    type: onDemand"
  echo "    onDemand:"
  echo "      plugins:"
  echo "        url:"
  for artifact in "${selected_artifacts[@]}"; do
    connector_name="$(basename "$(dirname "${artifact}")")"
    file_name="$(basename "${artifact}")"
    base_name="${file_name%.*}"
    s3_key="${PREFIX}/${connector_name}/${file_name}"
    s3_uri="s3://${BUCKET}/${s3_key}"
    archive_url="$(aws s3 presign "${s3_uri}" --expires-in 604800 --region "${AWS_REGION}")"
    checksum="$(checksum_for "${artifact}")"
    if [[ -z "$checksum" ]]; then
      echo "Failed to compute sha512 checksum for ${artifact}" >&2
      exit 1
    fi

    echo "          - name: ${base_name}"
    echo "            archivePath: ${archive_url}"
    echo "            checksum: ${checksum}"
  done
} > "${OUTPUT_PATH}"
