#!/usr/bin/env bash
set -euo pipefail

CONNECT_URL="${CONNECT_URL:-}"
NAMESPACE="${CONNECT_NAMESPACE:-confluent}"
SERVICE_NAME="${CONNECT_SERVICE:-connect}"
LOCAL_PORT="${CONNECT_LOCAL_PORT:-8083}"
KUBE_CONTEXT="${CONNECT_KUBE_CONTEXT:-}"
CONNECTOR_NAME="${CONNECTOR_NAME:-snowflake-sink}"
CONNECTOR_CLASS="${CONNECTOR_CLASS:-com.snowflake.kafka.connector.SnowflakeSinkConnector}"
CHECK_PLUGIN_ONLY="${CHECK_PLUGIN_ONLY:-0}"
TIMEOUT_SECONDS="${CONNECT_WAIT_TIMEOUT:-300}"

KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  rm -f "${TMP_PLUGINS:-}" "${TMP_STATUS:-}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_connect_pod_ready() {
  local deadline phase ready
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    phase="$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    ready="$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" && "$ready" == "true" ]]; then
      return 0
    fi
    sleep 3
  done
  echo "Timed out waiting for pod/connect-0 to become Running+Ready in namespace ${NAMESPACE}"
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o wide || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" describe pod connect-0 || true
  return 1
}

if [[ -z "$CONNECT_URL" ]]; then
  if ! kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get svc "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "Service not found: ${SERVICE_NAME} in namespace ${NAMESPACE}"
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get svc || true
    exit 1
  fi

  echo "CONNECT_URL not set; using kubectl port-forward to ${SERVICE_NAME} in ${NAMESPACE}..."
  wait_for_connect_pod_ready
  connected=0
  for attempt in 1 2 3; do
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" port-forward "svc/${SERVICE_NAME}" "${LOCAL_PORT}:8083" >/tmp/connect-port-forward.log 2>&1 &
    PF_PID=$!

    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      if curl -fsS "http://localhost:${LOCAL_PORT}/connector-plugins" >/dev/null 2>&1; then
        connected=1
        break
      fi
      if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    if [[ "$connected" == "1" ]]; then
      break
    fi

    kill "$PF_PID" >/dev/null 2>&1 || true
    unset PF_PID
    echo "Port-forward attempt ${attempt}/3 failed; checking Connect pod status before retry..."
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o wide || true
    wait_for_connect_pod_ready
  done

  if [[ "$connected" != "1" ]]; then
    echo "Port-forward process exited before Connect became reachable."
    cat /tmp/connect-port-forward.log || true
    echo "Connect service:"
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get svc "$SERVICE_NAME" -o wide || true
    echo "Connect pod:"
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o wide || true
    exit 1
  fi
  CONNECT_URL="http://localhost:${LOCAL_PORT}"
fi

TMP_PLUGINS="$(mktemp)"
TMP_STATUS="$(mktemp)"

echo "🔎 Checking plugin availability: ${CONNECTOR_CLASS}"
curl -sS "${CONNECT_URL}/connector-plugins" >"$TMP_PLUGINS"

if command -v python >/dev/null 2>&1; then
  PLUGIN_FOUND="$(python - <<'PY' "$TMP_PLUGINS" "$CONNECTOR_CLASS"
import json
import sys

path, klass = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
found = any(item.get("class") == klass for item in data if isinstance(item, dict))
print("yes" if found else "no")
PY
)"
else
  PLUGIN_FOUND="$(grep -c "\"class\":\"${CONNECTOR_CLASS}\"" "$TMP_PLUGINS" || true)"
  [[ "$PLUGIN_FOUND" != "0" ]] && PLUGIN_FOUND="yes" || PLUGIN_FOUND="no"
fi

if [[ "$PLUGIN_FOUND" != "yes" ]]; then
  echo "❌ Plugin class not found in Connect: ${CONNECTOR_CLASS}"
  echo "Available plugins:"
  if command -v python >/dev/null 2>&1; then
    python - <<'PY' "$TMP_PLUGINS"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for item in data:
    if isinstance(item, dict) and item.get("class"):
        print(f"- {item['class']} ({item.get('type', 'unknown')})")
PY
  else
    cat "$TMP_PLUGINS"
  fi
  exit 2
fi
echo "✅ Plugin class is available."

if [[ "$CHECK_PLUGIN_ONLY" == "1" ]]; then
  echo "✅ Plugin-only check requested; skipping connector runtime status check."
  exit 0
fi

echo "🔎 Checking connector runtime status: ${CONNECTOR_NAME}"
set +e
STATUS_HTTP_CODE="$(curl -sS -o "$TMP_STATUS" -w '%{http_code}' "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status")"
set -e

if [[ "$STATUS_HTTP_CODE" != "200" ]]; then
  echo "❌ Connector status endpoint returned HTTP ${STATUS_HTTP_CODE} for ${CONNECTOR_NAME}"
  echo "Response:"
  cat "$TMP_STATUS"
  exit 3
fi

if command -v python >/dev/null 2>&1; then
  python - <<'PY' "$TMP_STATUS" "$CONNECTOR_NAME"
import json
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

connector_state = ((data.get("connector") or {}).get("state") or "").upper()
tasks = data.get("tasks") or []
task_states = [str((t.get("state") or "")).upper() for t in tasks if isinstance(t, dict)]
all_running = bool(task_states) and all(s == "RUNNING" for s in task_states)

print(f"Connector: {name}")
print(f"Connector state: {connector_state or 'UNKNOWN'}")
print(f"Task states: {', '.join(task_states) if task_states else 'none'}")

if connector_state != "RUNNING" or not all_running:
    sys.exit(4)
PY
else
  cat "$TMP_STATUS"
fi

echo "✅ Connector is rolled out and running."
