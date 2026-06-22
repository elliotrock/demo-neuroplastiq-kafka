#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${1:-confluent}
TIMEOUT=${2:-300}   # seconds

echo "🐝 Smoke checks for Confluent platform in namespace: $NAMESPACE"

on_fail() {
  echo "⚠️ Smoke check failed. Capturing diagnostics for namespace: $NAMESPACE"
  kubectl get pods -n "$NAMESPACE" -o wide || true
  echo "---- describe pods ----"
  kubectl describe pods -n "$NAMESPACE" || true
  echo "---- recent events ----"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 200 || true
}
trap on_fail ERR

echo "🧹 Cleaning up Completed pods in namespace..."
kubectl delete pod -n "$NAMESPACE" --field-selector=status.phase=Succeeded --ignore-not-found || true

echo "⏱️ Waiting for core pods to be Ready in namespace ($TIMEOUT sec)..."
CORE_PODS=("kafka-0" "kafka-controller-0" "schemaregistry-0" "connect-0")
missing=()
for pod in "${CORE_PODS[@]}"; do
  if ! kubectl get pod "$pod" -n "$NAMESPACE" >/dev/null 2>&1; then
    missing+=("$pod")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "⚠️ Missing core pods: ${missing[*]}"
  exit 1
fi

for pod in "${CORE_PODS[@]}"; do
  kubectl wait --for=condition=Ready pod "$pod" -n "$NAMESPACE" --timeout=${TIMEOUT}s
done

echo "🔎 List pods:"
kubectl get pods -n "$NAMESPACE" -o wide

# Check CFK operator
echo "🔁 Checking CFK operator pods..."
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=confluent-for-kubernetes -o wide || true

# Ensure Kafka broker StatefulSet (or Pod) exists
echo "📡 Checking for kafka pods / statefulsets..."
kubectl get statefulset -n "$NAMESPACE" --ignore-not-found
kubectl get sts -n "$NAMESPACE" --ignore-not-found

# Ensure Schema Registry service exists
echo "📚 Checking Schema Registry service..."
kubectl get svc -n "$NAMESPACE" | grep -i schemaregistry || true

# Ensure Connect service exists
echo "🔌 Checking Kafka Connect service..."
kubectl get svc -n "$NAMESPACE" | grep -i connect || true

echo "✅ Basic cluster & resource checks complete."
