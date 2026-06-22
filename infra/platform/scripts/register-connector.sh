#!/usr/bin/env bash
set -euo pipefail

CONNECTOR_CONFIG="${1:-${CONNECTOR_CONFIG:-confluent/config/connectors/snowflake/snowflake-sink.json}}"
CONNECT_URL="${CONNECT_URL:-}"
NAMESPACE="${CONNECT_NAMESPACE:-confluent}"
SERVICE_NAME="${CONNECT_SERVICE:-connect}"
LOCAL_PORT="${CONNECT_LOCAL_PORT:-8083}"
KUBE_CONTEXT="${CONNECT_KUBE_CONTEXT:-}"
CURL_CONNECT_TIMEOUT="${CONNECT_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CONNECT_CURL_MAX_TIME:-20}"
KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi

if [[ ! -f "$CONNECTOR_CONFIG" ]]; then
  echo "Connector config not found: $CONNECTOR_CONFIG"
  exit 1
fi

get_connector_name() {
  if command -v python >/dev/null 2>&1; then
    python - <<'PY' "$CONNECTOR_CONFIG"
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
name = data.get("name", "")
print(name)
PY
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '.name // empty' "$CONNECTOR_CONFIG"
    return
  fi

  return 1
}

CONNECTOR_NAME="$(get_connector_name || true)"
if [[ -z "$CONNECTOR_NAME" ]]; then
  echo "Connector name missing. Set CONNECTOR_NAME or ensure 'name' exists in $CONNECTOR_CONFIG."
  exit 1
fi

get_connector_payload() {
  local out_file="$1"
  if command -v python >/dev/null 2>&1; then
    python - <<'PY' "$CONNECTOR_CONFIG" "$out_file"
import json
import os
import sys

src = sys.argv[1]
dest = sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
if isinstance(data, dict) and isinstance(data.get("config"), dict):
    payload = data["config"]
else:
    payload = data
key = os.environ.get("SNOWFLAKE_PRIVATE_KEY_P8") or os.environ.get("SNOWFLAKE_PRIVATE_KEY")
if isinstance(payload, dict) and key:
    current = payload.get("snowflake.private.key")
    if not current or current in ("<PEM_PRIVATE_KEY>", "PEM_PRIVATE_KEY"):
        payload["snowflake.private.key"] = key
with open(dest, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PY
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    if jq -e '.config and (.config | type=="object")' "$CONNECTOR_CONFIG" >/dev/null 2>&1; then
      jq '.config' "$CONNECTOR_CONFIG" >"$out_file"
    else
      cat "$CONNECTOR_CONFIG" >"$out_file"
    fi
    key="${SNOWFLAKE_PRIVATE_KEY_P8:-${SNOWFLAKE_PRIVATE_KEY:-}}"
    if [[ -n "$key" ]]; then
      jq --arg key "$key" \
        'if (.["snowflake.private.key"] | not) or .["snowflake.private.key"] == "" or .["snowflake.private.key"] == "<PEM_PRIVATE_KEY>" or .["snowflake.private.key"] == "PEM_PRIVATE_KEY"
         then .["snowflake.private.key"] = $key else . end' \
        "$out_file" >"${out_file}.tmp"
      mv "${out_file}.tmp" "$out_file"
    fi
    return
  fi

  return 1
}

cleanup_pf() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PAYLOAD_FILE:-}" && -f "${PAYLOAD_FILE}" ]]; then
    rm -f "$PAYLOAD_FILE" >/dev/null 2>&1 || true
  fi
  if [[ -n "${RESPONSE_FILE:-}" && -f "${RESPONSE_FILE}" ]]; then
    rm -f "$RESPONSE_FILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup_pf EXIT

if [[ -z "$CONNECT_URL" ]]; then
  if ! kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get svc "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "Service not found: ${SERVICE_NAME} in namespace ${NAMESPACE}"
    echo "Available services:"
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get svc
    exit 1
  fi

  echo "CONNECT_URL not set; using kubectl port-forward to ${SERVICE_NAME} in ${NAMESPACE}..."
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" port-forward "svc/${SERVICE_NAME}" "${LOCAL_PORT}:8083" >/tmp/connect-port-forward.log 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 10); do
    if curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -sS "http://localhost:${LOCAL_PORT}/connectors" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  CONNECT_URL="http://localhost:${LOCAL_PORT}"
fi

PAYLOAD_FILE="$(mktemp)"
if ! get_connector_payload "$PAYLOAD_FILE"; then
  echo "Unable to build connector payload. Install python or jq."
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  if jq -e 'has("snowflake.private.key") and (.["snowflake.private.key"] == "" or .["snowflake.private.key"] == "<PEM_PRIVATE_KEY>" or .["snowflake.private.key"] == "PEM_PRIVATE_KEY")' "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "snowflake.private.key is missing or still a placeholder. Set SNOWFLAKE_PRIVATE_KEY_P8 or SNOWFLAKE_PRIVATE_KEY."
    exit 1
  fi
fi

if [[ -n "${DEBUG_CONNECTOR_PAYLOAD:-}" ]]; then
  echo "Connector payload (redacted if possible):"
  if command -v jq >/dev/null 2>&1; then
    jq 'if has("snowflake.private.key") then .["snowflake.private.key"]="<redacted>" else . end' "$PAYLOAD_FILE"
  else
    cat "$PAYLOAD_FILE"
  fi
fi

echo "Applying connector ${CONNECTOR_NAME} to ${CONNECT_URL}"
RESPONSE_FILE="$(mktemp)"
HTTP_CODE="$(curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -sS -o "$RESPONSE_FILE" -w '%{http_code}' -X PUT -H "Content-Type: application/json" \
  --data @"${PAYLOAD_FILE}" \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/config")" || {
  echo "Connect REST call failed. Port-forward log:"
  cat /tmp/connect-port-forward.log || true
  exit 1
}
if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "Connector apply failed with HTTP ${HTTP_CODE}"
  cat "$RESPONSE_FILE" || true
  if [[ "$HTTP_CODE" == "500" ]] && grep -qi 'Request timed out' "$RESPONSE_FILE"; then
    echo "Connect returned timeout; checking if connector was created asynchronously..."
    for i in $(seq 1 15); do
      echo "Async check ${i}/15 for connector ${CONNECTOR_NAME}..."
      if curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -fsS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}" >/dev/null 2>&1; then
        echo "Connector ${CONNECTOR_NAME} exists despite timeout; proceeding."
        exit 0
      fi
      sleep 2
    done
  fi
  exit 1
fi
cat "$RESPONSE_FILE"
echo
