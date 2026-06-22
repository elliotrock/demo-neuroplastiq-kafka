#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-confluent}"
KAFKA_NAME="${2:-kafka}"
TIMEOUT_SECONDS="${3:-900}"

deadline=$((SECONDS + TIMEOUT_SECONDS))

echo "Kafka storage gate: namespace=${NAMESPACE} kafka=${KAFKA_NAME}"

while true; do
  desired_capacity="$(
    kubectl -n "${NAMESPACE}" get kafka "${KAFKA_NAME}" \
      -o jsonpath='{.spec.dataVolumeCapacity}' 2>/dev/null || true
  )"
  replicas="$(
    kubectl -n "${NAMESPACE}" get kafka "${KAFKA_NAME}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"

  if [[ -z "${desired_capacity}" || -z "${replicas}" ]]; then
    echo "Waiting for Kafka CR ${NAMESPACE}/${KAFKA_NAME} to expose storage spec..."
    sleep 10
    continue
  fi

  not_ready=0
  for ((i = 0; i < replicas; i++)); do
    pvc="data0-${KAFKA_NAME}-${i}"
    capacity="$(
      kubectl -n "${NAMESPACE}" get pvc "${pvc}" \
        -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true
    )"
    conditions="$(
      kubectl -n "${NAMESPACE}" get pvc "${pvc}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}:{.reason};{end}' 2>/dev/null || true
    )"

    if [[ "${capacity}" != "${desired_capacity}" ]]; then
      echo "PVC ${pvc}: capacity=${capacity:-unknown} desired=${desired_capacity} conditions=${conditions:-none}"
      not_ready=1
    fi
  done

  if (( not_ready == 0 )); then
    echo "Kafka PVC capacities match desired size: ${desired_capacity}"
    break
  fi

  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for Kafka PVC resize to complete."
    kubectl -n "${NAMESPACE}" get kafka "${KAFKA_NAME}" -o wide || true
    kubectl -n "${NAMESPACE}" get pvc -l app="${KAFKA_NAME}" || true
    kubectl -n "${NAMESPACE}" get pvc "data0-${KAFKA_NAME}-0" "data0-${KAFKA_NAME}-1" "data0-${KAFKA_NAME}-2" 2>/dev/null || true
    exit 1
  fi

  sleep 15
done

for ((i = 0; i < replicas; i++)); do
  pod="${KAFKA_NAME}-${i}"
  if kubectl -n "${NAMESPACE}" get pod "${pod}" >/dev/null 2>&1; then
    echo "Disk usage for ${pod}:"
    kubectl -n "${NAMESPACE}" exec "${pod}" -c kafka -- df -h /mnt/data/data0 2>/dev/null || true
  fi
done

echo "Kafka storage gate passed."
