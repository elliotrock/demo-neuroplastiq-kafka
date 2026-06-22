#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-confluent}"
BROKER_SERVICE="${2:-kafka}"
BOOTSTRAP_PORT="${3:-9092}"
EXPECTED_BROKERS="${4:-3}"
TIMEOUT_SECONDS="${5:-600}"
# Internal topics that are noisy/non-critical in staging can be ignored by default.
# Override with KAFKA_URP_IGNORE_REGEX="" to enforce strict checks on all topics.
KAFKA_URP_IGNORE_REGEX="${KAFKA_URP_IGNORE_REGEX:-^(_confluent-telemetry-metrics|_confluent_balancer_api_state|_confluent-metrics)$}"
# strict: fail on any remaining URP after ignore filter
# leader-only: fail only on leaderless URP ("Leader: none"), warn on other URP
KAFKA_URP_MODE="${KAFKA_URP_MODE:-strict}"

deadline=$((SECONDS + TIMEOUT_SECONDS))

echo "🔎 Kafka health gate: namespace=${NAMESPACE} brokers=${EXPECTED_BROKERS}"

until true; do
  ready_brokers="$(kubectl get pods -n "${NAMESPACE}" -l app=kafka --no-headers 2>/dev/null | awk '$2=="1/1" {count++} END {print count+0}')"
  if [[ "${ready_brokers}" -ge "${EXPECTED_BROKERS}" ]]; then
    echo "✅ Kafka broker pods Ready: ${ready_brokers}/${EXPECTED_BROKERS}"
    break
  fi

  if [[ $SECONDS -ge $deadline ]]; then
    echo "❌ Timed out waiting for Kafka brokers to become Ready (${ready_brokers}/${EXPECTED_BROKERS})"
    kubectl get pods -n "${NAMESPACE}" -o wide || true
    exit 1
  fi
  echo "⏳ Waiting for Kafka brokers Ready (${ready_brokers}/${EXPECTED_BROKERS})..."
  sleep 15
done

echo "🔎 Checking under-replicated partitions..."
under_replication_deadline=$((SECONDS + TIMEOUT_SECONDS))
while true; do
  under_replicated_raw="$(
    kubectl -n "${NAMESPACE}" exec kafka-0 -c kafka -- \
      kafka-topics --bootstrap-server "${BROKER_SERVICE}:${BOOTSTRAP_PORT}" \
      --describe --under-replicated-partitions 2>/dev/null || true
  )"
  if [[ -n "${KAFKA_URP_IGNORE_REGEX}" ]]; then
    under_replicated="$(
      awk -v re="${KAFKA_URP_IGNORE_REGEX}" '
        {
          topic=""
          if (match($0, /Topic: [^ \t]+/)) {
            topic=substr($0, RSTART+7, RLENGTH-7)
          }
          if (topic == "" || topic !~ re) {
            print $0
          }
        }
      ' <<< "${under_replicated_raw}"
    )"
  else
    under_replicated="${under_replicated_raw}"
  fi
  actionable_under_replicated="${under_replicated}"
  if [[ "${KAFKA_URP_MODE}" == "leader-only" ]]; then
    actionable_under_replicated="$(grep -E 'Leader:\s*none' <<< "${under_replicated}" || true)"
  fi

  if [[ -z "${actionable_under_replicated}" ]]; then
    if [[ -n "${under_replicated}" && "${KAFKA_URP_MODE}" == "leader-only" ]]; then
      echo "⚠️ Under-replicated partitions remain, but none are leaderless (mode=leader-only)."
      echo "${under_replicated}"
    fi
    echo "✅ No under-replicated partitions."
    break
  fi

  if [[ $SECONDS -ge $under_replication_deadline ]]; then
    echo "❌ Under-replicated partitions still present after timeout:"
    echo "${actionable_under_replicated}"
    echo "🧾 Broker pod snapshot:"
    kubectl get pods -n "${NAMESPACE}" -l app=kafka -o wide || true
    exit 1
  fi

  echo "⏳ Under-replicated partitions still present; waiting for convergence..."
  echo "${actionable_under_replicated}"
  if [[ -n "${KAFKA_URP_IGNORE_REGEX}" ]]; then
    echo "ℹ️ Ignoring URP topics matching regex: ${KAFKA_URP_IGNORE_REGEX}"
  fi
  echo "ℹ️ URP mode: ${KAFKA_URP_MODE}"
  sleep 20
done

echo "🔎 Checking _confluent-command topic health..."
command_topic="$(
  kubectl -n "${NAMESPACE}" exec kafka-0 -c kafka -- \
    kafka-topics --bootstrap-server "${BROKER_SERVICE}:${BOOTSTRAP_PORT}" \
    --describe --topic _confluent-command 2>/dev/null || true
)"
if [[ -z "${command_topic}" ]]; then
  echo "❌ Unable to describe _confluent-command topic"
  exit 1
fi
echo "${command_topic}"

if ! grep -q "Leader:" <<< "${command_topic}"; then
  echo "❌ _confluent-command topic has no leader metadata"
  exit 1
fi

if grep -Eq 'Offline:\s+[0-9]+' <<< "${command_topic}"; then
  echo "❌ _confluent-command has offline replicas"
  exit 1
fi

echo "✅ Kafka health gate passed."
