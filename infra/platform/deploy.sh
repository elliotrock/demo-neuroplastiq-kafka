#!/usr/bin/env bash
set -e

NAMESPACE="confluent"
ENVIRONMENT="${1:-dev}"   # default to dev
VALUES_FILE="../environments/${ENVIRONMENT}/values-${ENVIRONMENT}.yaml"

echo "🚀 Deploying Confluent Platform for environment: $ENVIRONMENT"
echo "📄 Using values file: $VALUES_FILE"

if [ ! -f "$VALUES_FILE" ]; then
  echo "❌ ERROR: Values file not found: $VALUES_FILE"
  exit 1
fi

echo "📦 Adding Confluent Helm repo…"
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

echo "🛠 Deploying CFK Operator…"
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace "$NAMESPACE" --create-namespace

echo "🧠 Deploying Confluent Platform Helm chart…"
helm upgrade --install confluent-platform ./charts/confluent-platform \
  -n "$NAMESPACE" -f "$VALUES_FILE"

echo "🎉 Confluent Platform successfully deployed!"
kubectl get pods -n "$NAMESPACE"
