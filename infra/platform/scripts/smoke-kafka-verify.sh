#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${1:-confluent}
BROKER_SERVICE=${2:-kafka}              # service name in cluster
BOOTSTRAP_PORT=${3:-9092}
SCHEMA_REGISTRY_HOST=${4:-schemaregistry}
SCHEMA_REGISTRY_PORT=${5:-8081}
CONNECT_HOST=${6:-connect}
CONNECT_PORT=${7:-8083}
TIMEOUT=${8:-120}
SMOKE_TOPIC_RF=${SMOKE_TOPIC_RF:-}

IMAGE="confluentinc/cp-kafka:7.6.1"  # change if you use another image
RUN_ID="$(date +%s)"
TOPIC="smoke-test-topic-${RUN_ID}"
MESSAGE="hello-bookibet-${RUN_ID}"
POD_KAFKA_CLI="kafka-cli-${RUN_ID}"
POD_KAFKA_PRODUCE="kafka-produce-${RUN_ID}"
POD_KAFKA_CONSUME="kafka-consume-${RUN_ID}"
POD_SR_CLIENT="sr-client-${RUN_ID}"
POD_CHECK_CONNECT="check-connect-${RUN_ID}"

detect_smoke_topic_rf() {
  if [[ -n "$SMOKE_TOPIC_RF" ]]; then
    echo "$SMOKE_TOPIC_RF"
    return 0
  fi

  local ready_brokers
  ready_brokers="$(kubectl get pods -n "$NAMESPACE" -l app=kafka -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)"
  if [[ -z "$ready_brokers" ]] || (( ready_brokers < 1 )); then
    echo "1"
    return 0
  fi

  if (( ready_brokers >= 3 )); then
    echo "3"
  else
    echo "$ready_brokers"
  fi
}

cleanup_run_pods() {
  kubectl delete pod -n "$NAMESPACE" --ignore-not-found=true \
    "$POD_KAFKA_CLI" \
    "$POD_KAFKA_PRODUCE" \
    "$POD_KAFKA_CONSUME" \
    "$POD_SR_CLIENT" \
    "$POD_CHECK_CONNECT" >/dev/null 2>&1 || true
}

dump_namespace_diagnostics() {
  echo "🧾 Diagnostics: namespace=$NAMESPACE"
  kubectl get pods -n "$NAMESPACE" -o wide || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 50 || true
}

dump_pod_diagnostics() {
  local pod="$1"
  local container="${2:-}"
  echo "🧾 Diagnostics: pod=$pod container=${container:-default}"
  kubectl describe pod "$pod" -n "$NAMESPACE" || true
  if [ -n "$container" ]; then
    kubectl logs "$pod" -n "$NAMESPACE" -c "$container" --tail=200 || true
  else
    kubectl logs "$pod" -n "$NAMESPACE" --tail=200 || true
  fi
}

on_error() {
  echo "❌ Smoke tests failed; collecting diagnostics..."
  dump_namespace_diagnostics
  dump_pod_diagnostics "kafka-0" "kafka"
  dump_pod_diagnostics "kafka-controller-0" "kafka-controller"
  dump_pod_diagnostics "schemaregistry-0" "schemaregistry"
  dump_pod_diagnostics "connect-0" "connect"
}

trap on_error ERR
trap cleanup_run_pods EXIT

echo "🌩 Running Kafka smoke E2E tests in namespace: $NAMESPACE"
echo "🧪 Producer -> Topic: $TOPIC"
TOPIC_RF="$(detect_smoke_topic_rf)"
echo "🧪 Smoke topic replication factor: ${TOPIC_RF}"

# Defensive cleanup for reruns that re-use RUN_ID in the same second.
cleanup_run_pods

# 1) Create topic via ephemeral admin container (if topic auto-create disabled)
kubectl run "$POD_KAFKA_CLI" -n "$NAMESPACE" --image="$IMAGE" --restart=Never --rm --attach --command -- \
  bash -c "export KAFKA_OPTS=''; /usr/bin/kafka-topics --bootstrap-server ${BROKER_SERVICE}:${BOOTSTRAP_PORT} --create --topic ${TOPIC} --partitions 1 --replication-factor ${TOPIC_RF} || true"

# 2) Produce a single message
set +e
produce_output=$(kubectl run "$POD_KAFKA_PRODUCE" -n "$NAMESPACE" --image="$IMAGE" --restart=Never --rm --attach --command -- \
  bash -c "echo '${MESSAGE}' | /usr/bin/kafka-console-producer --broker-list ${BROKER_SERVICE}:${BOOTSTRAP_PORT} --topic ${TOPIC}" 2>&1)
produce_status=$?
set -e
if [ $produce_status -ne 0 ]; then
  echo "❌ Producer failed with exit code ${produce_status}"
  echo "🧾 Producer output:"
  echo "$produce_output"
  exit $produce_status
fi

# Wait a few seconds
sleep 3

# 3) Consume the message (timeout guarded)
echo "📥 Consuming message from topic (will timeout after ${TIMEOUT}s)..."
set +e
consume_output=$(kubectl run "$POD_KAFKA_CONSUME" -n "$NAMESPACE" --image="$IMAGE" --restart=Never --rm --attach --command -- \
  bash -c "timeout ${TIMEOUT} /usr/bin/kafka-console-consumer --bootstrap-server ${BROKER_SERVICE}:${BOOTSTRAP_PORT} --topic ${TOPIC} --from-beginning --max-messages 1" 2>&1)
consume_status=$?
set -e
if [ $consume_status -ne 0 ]; then
  echo "❌ Consumer failed with exit code ${consume_status}"
  echo "🧾 Consumer output:"
  echo "$consume_output"
  exit $consume_status
fi
if ! echo "$consume_output" | grep -q "${MESSAGE}"; then
  echo "❌ Expected message not found in consumer output"
  echo "🧾 Consumer output:"
  echo "$consume_output"
  exit 1
fi

echo "✅ Kafka produce/consume OK: '${MESSAGE}'"

# 4) Register a schema with Schema Registry
SCHEMA_JSON=$(cat <<'JSON'
{"type":"record","name":"TestRecord","fields":[{"name":"message","type":"string"}]}
JSON
)

echo "📚 Registering a test Avro schema to Schema Registry..."
set +e
sr_output=$(kubectl run "$POD_SR_CLIENT" -n "$NAMESPACE" --image=curlimages/curl:8.2.1 --restart=Never --rm --attach --command -- \
  sh -c "curl -sS -w '\nHTTP_STATUS:%{http_code}\n' -X POST \
     -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
     --data '{\"schema\": \"$(printf '%s' "$SCHEMA_JSON" | sed 's/\"/\\\"/g')\"}' \
     http://${SCHEMA_REGISTRY_HOST}:${SCHEMA_REGISTRY_PORT}/subjects/${TOPIC}-value/versions" 2>&1)
sr_status=$?
set -e
sr_http_status=$(printf '%s' "$sr_output" | awk -F: '/HTTP_STATUS/ {print $2}' | tail -n 1)
if [ $sr_status -ne 0 ] || ! printf '%s' "$sr_http_status" | grep -Eq '^(2[0-9]{2})$'; then
  echo "❌ Schema Registry registration failed"
  echo "🧾 SR output:"
  echo "$sr_output"
  exit 1
fi

echo "✅ Schema Registry registration attempt complete."

# 5) Check Connect REST API (list connectors)
echo "🔌 Checking Kafka Connect REST API..."
set +e
connect_output=$(kubectl run "$POD_CHECK_CONNECT" -n "$NAMESPACE" --image=curlimages/curl:8.2.1 --restart=Never --rm --attach --command -- \
  sh -c "curl -sS -w '\nHTTP_STATUS:%{http_code}\n' http://${CONNECT_HOST}:${CONNECT_PORT}/connectors" 2>&1)
connect_status=$?
set -e
connect_http_status=$(printf '%s' "$connect_output" | awk -F: '/HTTP_STATUS/ {print $2}' | tail -n 1)
if [ $connect_status -ne 0 ] || ! printf '%s' "$connect_http_status" | grep -Eq '^(2[0-9]{2})$'; then
  echo "❌ Connect REST check failed"
  echo "🧾 Connect output:"
  echo "$connect_output"
  exit 1
fi

echo "✅ Connect REST check executed."

echo "🧾 Collecting post-check diagnostics..."
dump_namespace_diagnostics
dump_pod_diagnostics "kafka-0" "kafka"
dump_pod_diagnostics "kafka-controller-0" "kafka-controller"
dump_pod_diagnostics "schemaregistry-0" "schemaregistry"
dump_pod_diagnostics "connect-0" "connect"

echo "🎉 Smoke tests finished. Inspect logs if anything failed."
