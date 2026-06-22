#!/usr/bin/env bash
set -euo pipefail

TOPIC="${TOPIC:-bm_test}"
TOPIC_PARTITIONS="${TOPIC_PARTITIONS:-3}"
TOPIC_REPLICATION_FACTOR="${TOPIC_REPLICATION_FACTOR:-3}"
ALLOW_LOW_RF="${ALLOW_LOW_RF:-false}"
NAMESPACE="${NAMESPACE:-confluent}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

SR_SERVICE="${SCHEMA_REGISTRY_SERVICE:-schemaregistry}"
SR_PORT="${SCHEMA_REGISTRY_PORT:-8081}"
LOCAL_SR_PORT="${LOCAL_SCHEMA_REGISTRY_PORT:-18081}"

USE_KONG="${USE_KONG:-1}"
KONG_NAMESPACE="${KONG_NAMESPACE:-kong}"
KONG_PROXY_SERVICE="${KONG_PROXY_SERVICE:-kong-kong-proxy}"
KONG_PROXY_PORT="${KONG_PROXY_PORT:-80}"
LOCAL_KONG_PORT="${LOCAL_KONG_PORT:-18080}"
KONG_ROUTE_PREFIX="${KONG_ROUTE_PREFIX:-/data}"
KONG_API_KEY="${KONG_API_KEY:-bookibet-dev-key}"

REST_SERVICE="${KAFKA_REST_SERVICE:-kafka-rest}"
REST_PORT="${KAFKA_REST_PORT:-8082}"
LOCAL_REST_PORT="${LOCAL_KAFKA_REST_PORT:-18082}"

KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

require_service() {
  local name="$1"
  local namespace="${2:-$NAMESPACE}"
  if ! kubectl "${KUBECTL_ARGS[@]}" -n "$namespace" get svc "$name" >/dev/null 2>&1; then
    echo "Service not found: $name in namespace $namespace"
    exit 1
  fi
}

require_service "$SR_SERVICE" "$NAMESPACE"
if [[ "$USE_KONG" == "1" ]]; then
  require_service "$KONG_PROXY_SERVICE" "$KONG_NAMESPACE"
else
  require_service "$REST_SERVICE" "$NAMESPACE"
fi

cleanup_pf() {
  if [[ -n "${PF_SR_PID:-}" ]]; then
    kill "$PF_SR_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_KONG_PID:-}" ]]; then
    kill "$PF_KONG_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_REST_PID:-}" ]]; then
    kill "$PF_REST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_pf EXIT

kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" port-forward "svc/${SR_SERVICE}" "${LOCAL_SR_PORT}:${SR_PORT}" >/tmp/sr-port-forward.log 2>&1 &
PF_SR_PID=$!
if [[ "$USE_KONG" == "1" ]]; then
  kubectl "${KUBECTL_ARGS[@]}" -n "$KONG_NAMESPACE" port-forward "svc/${KONG_PROXY_SERVICE}" "${LOCAL_KONG_PORT}:${KONG_PROXY_PORT}" >/tmp/kong-port-forward.log 2>&1 &
  PF_KONG_PID=$!
  REST_BASE_URL="http://localhost:${LOCAL_KONG_PORT}${KONG_ROUTE_PREFIX}"
  REST_CURL_ARGS=(-H "apikey: ${KONG_API_KEY}")
else
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" port-forward "svc/${REST_SERVICE}" "${LOCAL_REST_PORT}:${REST_PORT}" >/tmp/rest-port-forward.log 2>&1 &
  PF_REST_PID=$!
  REST_BASE_URL="http://localhost:${LOCAL_REST_PORT}/v3"
  REST_CURL_ARGS=()
fi

for _ in $(seq 1 15); do
  if curl -sS "${REST_CURL_ARGS[@]}" "${REST_BASE_URL}/clusters" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

SCHEMA_JSON='{"type":"record","name":"TestRecord","fields":[{"name":"message","type":"string"}]}'

CLUSTER_ID=""
V3_RESP=""
V3_STATUS=""
if [[ -n "$PYTHON_BIN" ]]; then
  V3_STATUS=$(curl -sS -o /tmp/kafka-rest-clusters.json -w "%{http_code}" "${REST_CURL_ARGS[@]}" "${REST_BASE_URL}/clusters" || true)
  V3_RESP=$(cat /tmp/kafka-rest-clusters.json 2>/dev/null || true)
  if [[ -n "$V3_RESP" && ( "$V3_RESP" == \{* || "$V3_RESP" == \[* ) ]]; then
    CLUSTER_ID=$("$PYTHON_BIN" - <<'PY' "$V3_RESP"
import json
import sys

raw = sys.argv[1].strip()
if not raw:
    print("")
    sys.exit(0)
data = json.loads(raw)
clusters = data.get("data") or []
if clusters:
    print(clusters[0].get("cluster_id", ""))
PY
)
  fi
elif command -v jq >/dev/null 2>&1; then
  V3_STATUS=$(curl -sS -o /tmp/kafka-rest-clusters.json -w "%{http_code}" "${REST_CURL_ARGS[@]}" "${REST_BASE_URL}/clusters" || true)
  V3_RESP=$(cat /tmp/kafka-rest-clusters.json 2>/dev/null || true)
  if [[ -n "$V3_RESP" && ( "$V3_RESP" == \{* || "$V3_RESP" == \[* ) ]]; then
    CLUSTER_ID=$(printf '%s' "$V3_RESP" | jq -r '.data[0].cluster_id // empty')
  fi
fi

if [[ -z "$CLUSTER_ID" ]]; then
  echo "Unable to determine Kafka cluster id from REST Proxy."
  if [[ -n "$V3_STATUS" ]]; then
    echo "HTTP status from ${REST_BASE_URL}/clusters: ${V3_STATUS}"
  fi
  if [[ -z "$V3_RESP" ]]; then
    echo "Empty response body from ${REST_BASE_URL}/clusters"
  else
    echo "Response body from ${REST_BASE_URL}/clusters:"
    echo "$V3_RESP"
  fi
  if [[ "$USE_KONG" == "1" && -f /tmp/kong-port-forward.log ]]; then
    echo "Kong port-forward log:"
    cat /tmp/kong-port-forward.log
  elif [[ -f /tmp/rest-port-forward.log ]]; then
    echo "REST proxy port-forward log:"
    cat /tmp/rest-port-forward.log
  fi
  exit 1
fi

echo "Ensuring topic ${TOPIC} exists..."
if [[ "${TOPIC}" == betmaker.* ]] && [[ "${ALLOW_LOW_RF}" != "true" ]] && (( TOPIC_REPLICATION_FACTOR < 3 )); then
  echo "Refusing to create ${TOPIC} with TOPIC_REPLICATION_FACTOR=${TOPIC_REPLICATION_FACTOR}."
  echo "For betmaker.* topics, set TOPIC_REPLICATION_FACTOR>=3 (or ALLOW_LOW_RF=true to override)."
  exit 1
fi
if [[ -n "$RESET_TOPIC" ]]; then
  echo "RESET_TOPIC set; deleting ${TOPIC} if it exists..."
  DELETE_RESP=$(curl -sS -w "\n%{http_code}" -X DELETE \
    "${REST_CURL_ARGS[@]}" \
    "${REST_BASE_URL}/clusters/${CLUSTER_ID}/topics/${TOPIC}")
  DELETE_BODY=$(printf '%s' "$DELETE_RESP" | sed '$d')
  DELETE_CODE=$(printf '%s' "$DELETE_RESP" | tail -n 1)
  if [[ "$DELETE_CODE" != "200" && "$DELETE_CODE" != "204" && "$DELETE_CODE" != "404" ]]; then
    echo "Topic delete failed (${DELETE_CODE}): ${DELETE_BODY}"
    exit 1
  fi
fi

CREATE_RESP=$(curl -sS -w "\n%{http_code}" -X POST \
  "${REST_CURL_ARGS[@]}" \
  -H 'Content-Type: application/json' \
  --data "{\"topic_name\":\"${TOPIC}\",\"partitions_count\":${TOPIC_PARTITIONS},\"replication_factor\":${TOPIC_REPLICATION_FACTOR}}" \
  "${REST_BASE_URL}/clusters/${CLUSTER_ID}/topics")
CREATE_BODY=$(printf '%s' "$CREATE_RESP" | sed '$d')
CREATE_CODE=$(printf '%s' "$CREATE_RESP" | tail -n 1)
if [[ "$CREATE_CODE" == "400" ]] && printf '%s' "$CREATE_BODY" | grep -q '"error_code":40002'; then
  echo "Topic ${TOPIC} already exists; continuing."
elif [[ "$CREATE_CODE" != "200" && "$CREATE_CODE" != "201" && "$CREATE_CODE" != "409" ]]; then
  echo "Topic create failed (${CREATE_CODE}): ${CREATE_BODY}"
  exit 1
fi

echo "Registering schema for ${TOPIC}..."
SCHEMA_RESP=$(curl -sS -X POST \
  -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
  --data "{\"schema\":\"$(printf '%s' "$SCHEMA_JSON" | sed 's/\"/\\\"/g')\"}" \
  "http://localhost:${LOCAL_SR_PORT}/subjects/${TOPIC}-value/versions")
echo

SCHEMA_ID=""
if [[ -n "$PYTHON_BIN" ]]; then
  SCHEMA_ID=$("$PYTHON_BIN" - <<'PY' "$SCHEMA_RESP"
import json
import sys

raw = sys.argv[1].strip()
if not raw:
    print("")
    sys.exit(0)
data = json.loads(raw)
print(data.get("id", ""))
PY
)
elif command -v jq >/dev/null 2>&1; then
  SCHEMA_ID=$(printf '%s' "$SCHEMA_RESP" | jq -r '.id // empty')
fi

if [[ -z "$SCHEMA_ID" ]]; then
  echo "Unable to parse schema id from Schema Registry response."
  exit 1
fi

if [[ -n "$PYTHON_BIN" ]]; then
  PAYLOAD_JSON=$("$PYTHON_BIN" - <<'PY' "$SCHEMA_ID"
import json
import sys

schema_id = sys.argv[1]
payload = {
    "value": {
        "schema_id": int(schema_id),
        "data": {"message": "hello from bm_test"},
    }
}
print(json.dumps(payload))
PY
)
elif command -v jq >/dev/null 2>&1; then
  PAYLOAD_JSON=$(jq -n --arg schema_id "$SCHEMA_ID" \
    '{value:{schema_id:($schema_id|tonumber), data:{message:"hello from bm_test"}}}')
else
  echo "python/python3 or jq is required to build the Avro payload."
  exit 1
fi

echo "Producing message to ${TOPIC} via Kafka REST..."
curl -sS -X POST \
  "${REST_CURL_ARGS[@]}" \
  -H 'Content-Type: application/json' \
  --data "${PAYLOAD_JSON}" \
  "${REST_BASE_URL}/clusters/${CLUSTER_ID}/topics/${TOPIC}/records"
echo

echo "Done."
RESET_TOPIC="${RESET_TOPIC:-}"
