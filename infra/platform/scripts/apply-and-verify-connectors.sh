#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-${CONNECT_NAMESPACE:-confluent}}"
TIMEOUT_SECONDS="${2:-${CONNECT_WAIT_TIMEOUT:-600}}"
CONNECTORS_DIR="${3:-${CONNECTORS_DIR:-confluent/config/connectors}}"
CONNECT_SERVICE="${CONNECT_SERVICE:-connect}"
CONNECT_LOCAL_PORT="${CONNECT_LOCAL_PORT:-18083}"
CONNECT_URL="${CONNECT_URL:-}"
KUBE_CONTEXT="${CONNECT_KUBE_CONTEXT:-}"
CURL_CONNECT_TIMEOUT="${CONNECT_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CONNECT_CURL_MAX_TIME:-20}"
CONNECT_BOOTSTRAP_SERVER="${CONNECT_BOOTSTRAP_SERVER:-kafka.confluent.svc.cluster.local:9092}"
CONNECT_INTERNAL_TOPIC_AUTOREPAIR="${CONNECT_INTERNAL_TOPIC_AUTOREPAIR:-false}"
CONNECT_INTERNAL_TOPIC_RF_TARGET="${CONNECT_INTERNAL_TOPIC_RF_TARGET:-3}"
CONNECT_WAIT_RESTART_THRESHOLD="${CONNECT_WAIT_RESTART_THRESHOLD:-2}"

KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

emit_connect_diagnostics() {
  local reason="${1:-unspecified}"
  echo "---- Connect diagnostics (${reason}) ----"
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o wide || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get statefulset connect -o wide || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" describe pod connect-0 | tail -n 80 || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --tail=200 || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --previous --tail=200 || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --tail=400 | egrep -i "fatal|error|exception|listenernotfound|coordinator|notenoughreplicas|outofmemory|killed" || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --previous --tail=400 | egrep -i "fatal|error|exception|listenernotfound|coordinator|notenoughreplicas|outofmemory|killed" || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 40 || true
  for topic in connect-configs connect-offsets connect-statuses __consumer_offsets; do
    echo "Topic state: ${topic}"
    get_topic_description "$topic" || true
  done
  echo "---- End diagnostics ----"
}

wait_for_connect_ready_with_progress() {
  local phase_label="$1"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local prev_restarts=-1

  while (( SECONDS < deadline )); do
    local pod_state
    local pod_phase
    local ready
    local restarts
    local waiting_reason

    pod_state="$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o jsonpath='{.status.phase}|{.status.containerStatuses[0].ready}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    pod_phase="$(echo "$pod_state" | cut -d'|' -f1)"
    ready="$(echo "$pod_state" | cut -d'|' -f2)"
    restarts="$(echo "$pod_state" | cut -d'|' -f3)"
    waiting_reason="$(echo "$pod_state" | cut -d'|' -f4)"

    if [[ "$ready" == "true" ]]; then
      echo "Connect became Ready (${phase_label})."
      return 0
    fi

    echo "Connect wait (${phase_label}): phase=${pod_phase:-unknown} ready=${ready:-false} restarts=${restarts:-0} waitingReason=${waiting_reason:-none}"

    if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts != prev_restarts )); then
      echo "Connect restart count changed (${phase_label}): ${prev_restarts} -> ${restarts}"
      prev_restarts="$restarts"
      kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --previous --tail=120 || true
      kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --tail=120 || true
    fi

    if [[ "${waiting_reason:-}" == "CrashLoopBackOff" ]]; then
      echo "Connect is in CrashLoopBackOff (${phase_label}); failing fast."
      return 1
    fi

    if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= CONNECT_WAIT_RESTART_THRESHOLD )); then
      echo "Connect restart threshold reached (${phase_label}): restarts=${restarts} threshold=${CONNECT_WAIT_RESTART_THRESHOLD}"
      return 1
    fi

    sleep 10
  done

  return 1
}

get_topic_description() {
  local topic="$1"
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" exec kafka-0 -c kafka -- \
    kafka-topics --bootstrap-server "$CONNECT_BOOTSTRAP_SERVER" --describe --topic "$topic" 2>/dev/null || true
}

topic_needs_repair() {
  local topic="$1"
  local desc
  local rf
  local min_isr
  desc="$(get_topic_description "$topic")"
  if [[ -z "$desc" ]]; then
    # Topic missing means it can be freshly created by Connect.
    echo "Connect internal topic ${topic} does not exist yet (will be created by Connect)."
    return 1
  fi

  rf="$(printf '%s\n' "$desc" | sed -n 's/.*ReplicationFactor: \([0-9]\+\).*/\1/p' | head -n1)"
  min_isr="$(printf '%s\n' "$desc" | sed -n 's/.*min\.insync\.replicas=\([0-9]\+\).*/\1/p' | head -n1)"

  if [[ -z "$rf" ]]; then
    echo "Unable to parse replication factor for topic ${topic}; marking for repair."
    return 0
  fi
  if (( rf < CONNECT_INTERNAL_TOPIC_RF_TARGET )); then
    echo "Topic ${topic} has RF=${rf}, target=${CONNECT_INTERNAL_TOPIC_RF_TARGET}; marking for repair."
    return 0
  fi
  if [[ -n "$min_isr" ]] && (( min_isr > rf )); then
    echo "Topic ${topic} has minISR=${min_isr} > RF=${rf}; marking for repair."
    return 0
  fi
  return 1
}

repair_connect_internal_topics_if_needed() {
  local topics=("connect-configs" "connect-offsets" "connect-statuses")
  local needs_repair=0

  for topic in "${topics[@]}"; do
    if topic_needs_repair "$topic"; then
      needs_repair=1
      echo "Connect internal topic ${topic} is stale and requires repair."
      get_topic_description "$topic" || true
    fi
  done

  if (( needs_repair == 0 )); then
    echo "Connect internal topics look healthy."
    return 0
  fi

  if [[ "$CONNECT_INTERNAL_TOPIC_AUTOREPAIR" != "true" ]]; then
    echo "Connect internal topics require repair but CONNECT_INTERNAL_TOPIC_AUTOREPAIR=false."
    echo "Set CONNECT_INTERNAL_TOPIC_AUTOREPAIR=true or manually delete connect internal topics."
    return 1
  fi

  echo "Repairing stale Connect internal topics (non-prod safety path)..."
  emit_connect_diagnostics "before-repair"
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" scale statefulset connect --replicas=0
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" wait --for=delete pod/connect-0 --timeout=300s || true

  for topic in "${topics[@]}"; do
    echo "Deleting stale topic ${topic}..."
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" exec kafka-0 -c kafka -- \
      kafka-topics --bootstrap-server "$CONNECT_BOOTSTRAP_SERVER" \
      --delete --topic "$topic" || true
  done

  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" scale statefulset connect --replicas=1
  if ! kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" wait --for=condition=Ready pod/connect-0 --timeout="${TIMEOUT_SECONDS}s"; then
    emit_connect_diagnostics "repair-wait-timeout"
    return 1
  fi

  emit_connect_diagnostics "after-repair"
  echo "Connect internal topic repair completed."
}

if [[ ! -d "$CONNECTORS_DIR" ]]; then
  echo "Connectors directory not found: $CONNECTORS_DIR"
  exit 1
fi

echo "Waiting for Connect pod readiness in namespace=${NAMESPACE}..."
if ! wait_for_connect_ready_with_progress "initial"; then
  if [[ "$CONNECT_INTERNAL_TOPIC_AUTOREPAIR" == "true" ]]; then
    echo "Initial Connect readiness wait timed out; continuing to internal-topic repair path."
    emit_connect_diagnostics "initial-ready-timeout"
  else
    echo "Connect pod did not become Ready and auto-repair is disabled."
    emit_connect_diagnostics "initial-ready-timeout-no-autorepair"
    exit 1
  fi
fi

repair_connect_internal_topics_if_needed

echo "Ensuring Connect pod is Ready in namespace=${NAMESPACE}..."
if ! wait_for_connect_ready_with_progress "final"; then
  emit_connect_diagnostics "final-ready-timeout"
  exit 1
fi

if [[ -z "$CONNECT_URL" ]]; then
  echo "Waiting for Connect service=${CONNECT_SERVICE}..."
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get svc "$CONNECT_SERVICE" >/dev/null

  echo "Starting port-forward to Connect on localhost:${CONNECT_LOCAL_PORT}..."
  kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" port-forward "svc/${CONNECT_SERVICE}" "${CONNECT_LOCAL_PORT}:8083" >/tmp/connect-port-forward.log 2>&1 &
  PF_PID=$!

  CONNECT_URL="http://localhost:${CONNECT_LOCAL_PORT}"
fi

deadline=$((SECONDS + TIMEOUT_SECONDS))
until curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -fsS "${CONNECT_URL}/connector-plugins" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for Connect REST API at ${CONNECT_URL}"
    cat /tmp/connect-port-forward.log || true
    emit_connect_diagnostics "rest-api-timeout"
    exit 1
  fi
  sleep 2
done

shopt -s nullglob
configs=("${CONNECTORS_DIR}"/*.json "${CONNECTORS_DIR}"/*/*.json)
shopt -u nullglob

if [[ ${#configs[@]} -eq 0 ]]; then
  echo "No connector configs found under ${CONNECTORS_DIR}."
  exit 0
fi

for config in "${configs[@]}"; do
  connector_name="$(python - <<'PY' "$config"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("name", ""))
PY
)"

  connector_class="$(python - <<'PY' "$config"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
cfg = data.get("config", data)
if isinstance(cfg, dict):
    print(cfg.get("connector.class", ""))
else:
    print("")
PY
)"

  if [[ -z "$connector_name" ]]; then
    echo "Connector name missing in config: $config"
    exit 1
  fi
  if [[ -z "$connector_class" ]]; then
    echo "connector.class missing in config: $config"
    exit 1
  fi

  echo "Applying connector config ${config} (name=${connector_name})"
  applied=0
  for attempt in 1 2 3; do
    if CONNECT_URL="$CONNECT_URL" \
      CONNECT_NAMESPACE="$NAMESPACE" \
      CONNECT_SERVICE="$CONNECT_SERVICE" \
      CONNECT_KUBE_CONTEXT="$KUBE_CONTEXT" \
      CONNECTOR_CONFIG="$config" \
      infra/platform/scripts/register-connector.sh; then
      applied=1
      break
    fi
    echo "Connector apply attempt ${attempt}/3 failed for ${connector_name}; retrying..."
    sleep 5
  done
  if [[ "$applied" != "1" ]]; then
    echo "Failed to apply connector ${connector_name} after retries."
    echo "Connect diagnostics:"
    curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -sS "${CONNECT_URL}/connectors" || true
    echo
    curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -sS "${CONNECT_URL}/connector-plugins" || true
    echo
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod connect-0 -o wide || true
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs connect-0 --tail=200 || true
    exit 1
  fi

  visible_deadline=$((SECONDS + 120))
  until curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" -fsS "${CONNECT_URL}/connectors/${connector_name}" >/dev/null 2>&1; do
    if (( SECONDS >= visible_deadline )); then
      echo "Connector ${connector_name} was not created within 120s after apply."
      exit 1
    fi
    sleep 2
  done

  echo "Verifying connector status (name=${connector_name})"
  CONNECT_URL="$CONNECT_URL" \
    CONNECT_NAMESPACE="$NAMESPACE" \
    CONNECT_SERVICE="$CONNECT_SERVICE" \
    CONNECT_KUBE_CONTEXT="$KUBE_CONTEXT" \
    CONNECTOR_NAME="$connector_name" \
    CONNECTOR_CLASS="$connector_class" \
    infra/platform/scripts/check-snowflake-connector-status.sh
done

echo "All connector configs applied and verified."
