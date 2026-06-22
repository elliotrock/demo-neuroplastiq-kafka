#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-confluent}"
NODE_LABEL="${2:-workload.bookibet.io/pool}"
NODE_LABEL_VALUE="${3:-confluent}"
TIMEOUT_SECONDS="${4:-900}"

pods=(kafka-0 kafka-1 kafka-2 kafka-controller-0 connect-0 schemaregistry-0 kafka-rest-0)
deadline=$((SECONDS + TIMEOUT_SECONDS))
escaped_label="${NODE_LABEL//./\\.}"

echo "Confluent placement gate: namespace=${NAMESPACE} requiredNodeLabel=${NODE_LABEL}=${NODE_LABEL_VALUE}"

while true; do
  pending=0
  for pod in "${pods[@]}"; do
    node="$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [[ -z "${node}" ]]; then
      echo "Pod ${pod}: not scheduled yet"
      pending=1
      continue
    fi

    node_value="$(
      kubectl get node "${node}" -o "jsonpath={.metadata.labels.${escaped_label}}" 2>/dev/null || true
    )"
    if [[ "${node_value}" != "${NODE_LABEL_VALUE}" ]]; then
      echo "Pod ${pod}: node=${node} ${NODE_LABEL}=${node_value:-unset}, waiting for dedicated placement"
      pending=1
    fi
  done

  if (( pending == 0 )); then
    echo "All Confluent pods are scheduled on dedicated nodes."
    exit 0
  fi

  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for Confluent pods to move to dedicated nodes."
    kubectl -n "${NAMESPACE}" get pods -o wide || true
    kubectl get nodes -L "${NODE_LABEL}" -o wide || true
    exit 1
  fi
  sleep 15
done
