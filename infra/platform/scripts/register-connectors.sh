#!/usr/bin/env bash
set -euo pipefail

CONNECTORS_DIR="${1:-${CONNECTORS_DIR:-confluent/config/connectors}}"

if [[ ! -d "$CONNECTORS_DIR" ]]; then
  echo "Connectors directory not found: $CONNECTORS_DIR"
  exit 1
fi

shopt -s nullglob
configs=("${CONNECTORS_DIR}"/*.json "${CONNECTORS_DIR}"/*/*.json)
shopt -u nullglob

if [[ ${#configs[@]} -eq 0 ]]; then
  echo "No connector configs found in ${CONNECTORS_DIR}."
  exit 0
fi

for config in "${configs[@]}"; do
  echo "Applying connector config: ${config}"
  CONNECTOR_CONFIG="${config}" infra/platform/scripts/register-connector.sh
done
