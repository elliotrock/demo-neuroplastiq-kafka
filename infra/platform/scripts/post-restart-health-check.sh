#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
CONFLUENT_NAMESPACE="${CONFLUENT_NAMESPACE:-confluent}"

NEURO_NAMESPACE="${NEURO_NAMESPACE:-neuroplastiq}"
BOOKI_NAMESPACE="${BOOKI_NAMESPACE:-default}"

NEURO_SERVICE="${NEURO_SERVICE:-}"
BOOKI_SERVICE="${BOOKI_SERVICE:-}"

NEURO_PORT="${NEURO_PORT:-8000}"
BOOKI_PORT="${BOOKI_PORT:-8080}"

HEALTH_PATHS="${HEALTH_PATHS:-/health /healthz /ready /readyz /v1/health}"

KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi

find_service() {
  local namespace="$1"
  shift
  local candidates=("$@")
  local svc
  for svc in "${candidates[@]}"; do
    if kubectl "${KUBECTL_ARGS[@]}" -n "$namespace" get svc "$svc" >/dev/null 2>&1; then
      echo "$svc"
      return 0
    fi
  done
  return 1
}

check_service_endpoints() {
  local namespace="$1"
  local service="$2"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local count=0

  while (( SECONDS < deadline )); do
    count="$(kubectl "${KUBECTL_ARGS[@]}" -n "$namespace" get endpoints "$service" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      echo "✅ Endpoints ready: ${namespace}/${service} (${count})"
      return 0
    fi
    echo "⏳ Waiting endpoints: ${namespace}/${service}"
    sleep 5
  done

  echo "❌ Endpoints not ready: ${namespace}/${service}"
  kubectl "${KUBECTL_ARGS[@]}" -n "$namespace" get svc "$service" -o wide || true
  kubectl "${KUBECTL_ARGS[@]}" -n "$namespace" get endpoints "$service" -o wide || true
  return 1
}

check_http_health() {
  local namespace="$1"
  local service="$2"
  local port="$3"
  local path
  local code

  for path in $HEALTH_PATHS; do
    set +e
    code="$(kubectl "${KUBECTL_ARGS[@]}" -n "$namespace" run "healthcheck-${service}-$$" \
      --image=curlimages/curl:8.7.1 \
      --restart=Never --rm -i --quiet --command -- \
      sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://${service}.${namespace}.svc.cluster.local:${port}${path}" 2>/dev/null)"
    local rc=$?
    set -e
    if (( rc == 0 )) && [[ "$code" =~ ^2|3 ]]; then
      echo "✅ HTTP health: ${namespace}/${service}${path} -> ${code}"
      return 0
    fi
  done

  echo "❌ HTTP health failed for ${namespace}/${service} on port ${port}"
  echo "Tried paths: ${HEALTH_PATHS}"
  return 1
}

echo "=== Post-restart health check ==="
echo "Context: ${KUBE_CONTEXT:-current}"

if [[ -z "$NEURO_SERVICE" ]]; then
  NEURO_SERVICE="$(find_service "$NEURO_NAMESPACE" neuroplastiq neuroplastiq-api || true)"
fi
if [[ -z "$BOOKI_SERVICE" ]]; then
  BOOKI_SERVICE="$(find_service "$BOOKI_NAMESPACE" booki-platform booki-platform-api bookibet-platform-api bookibet-api || true)"
fi

if [[ -z "$NEURO_SERVICE" ]]; then
  echo "❌ Could not resolve Neuro service. Set NEURO_SERVICE=<name>."
  kubectl "${KUBECTL_ARGS[@]}" -n "$NEURO_NAMESPACE" get svc || true
  exit 1
fi
if [[ -z "$BOOKI_SERVICE" ]]; then
  echo "❌ Could not resolve Booki service. Set BOOKI_SERVICE=<name>."
  kubectl "${KUBECTL_ARGS[@]}" -n "$BOOKI_NAMESPACE" get svc || true
  exit 1
fi

echo "Neuro target: ${NEURO_NAMESPACE}/${NEURO_SERVICE}:${NEURO_PORT}"
echo "Booki target: ${BOOKI_NAMESPACE}/${BOOKI_SERVICE}:${BOOKI_PORT}"
echo "Confluent namespace: ${CONFLUENT_NAMESPACE}"

check_service_endpoints "$NEURO_NAMESPACE" "$NEURO_SERVICE"
check_http_health "$NEURO_NAMESPACE" "$NEURO_SERVICE" "$NEURO_PORT"

check_service_endpoints "$BOOKI_NAMESPACE" "$BOOKI_SERVICE"
check_http_health "$BOOKI_NAMESPACE" "$BOOKI_SERVICE" "$BOOKI_PORT"

infra/platform/scripts/smoke-kafka-health.sh "$CONFLUENT_NAMESPACE"
CONNECT_NAMESPACE="$CONFLUENT_NAMESPACE" infra/platform/scripts/check-snowflake-connector-status.sh

echo "✅ All gates passed: neuro + booki + confluent/connectors"
