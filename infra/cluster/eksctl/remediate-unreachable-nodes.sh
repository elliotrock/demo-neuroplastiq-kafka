#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-${CLUSTER_NAME:-}}"
AWS_REGION="${2:-${AWS_REGION:-ap-southeast-2}}"
APPLY="${APPLY:-0}"
DELETE_NODE_OBJECTS="${DELETE_NODE_OBJECTS:-1}"

if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "Usage: $0 <cluster-name> [aws-region]"
  echo "Optional env vars:"
  echo "  APPLY=1                 actually terminate ASG instances"
  echo "  DELETE_NODE_OBJECTS=1   delete unreachable node objects (default: 1)"
  exit 1
fi

echo "🔎 Scanning cluster=${CLUSTER_NAME} region=${AWS_REGION} for unreachable nodes..."

mapfile -t unreachable_nodes < <(
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.providerID}{"|"}{.spec.taints}{"\n"}{end}' \
    | awk -F'|' '$3 ~ /node.kubernetes.io\/unreachable/ { print $1 "|" $2 }'
)

if [[ ${#unreachable_nodes[@]} -eq 0 ]]; then
  echo "✅ No unreachable-tainted nodes found."
  exit 0
fi

echo "⚠️ Found unreachable nodes:"
for entry in "${unreachable_nodes[@]}"; do
  node_name="${entry%%|*}"
  provider_id="${entry#*|}"
  instance_id="${provider_id##*/}"
  echo " - ${node_name} (instance=${instance_id})"
done

if [[ "${APPLY}" != "1" ]]; then
  echo
  echo "Dry-run only. To remediate, run:"
  echo "  APPLY=1 $0 ${CLUSTER_NAME} ${AWS_REGION}"
  exit 0
fi

for entry in "${unreachable_nodes[@]}"; do
  node_name="${entry%%|*}"
  provider_id="${entry#*|}"
  instance_id="${provider_id##*/}"

  echo "🚧 Terminating instance ${instance_id} (no decrement)..."
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "${instance_id}" \
    --no-should-decrement-desired-capacity \
    --region "${AWS_REGION}"

  if [[ "${DELETE_NODE_OBJECTS}" == "1" ]]; then
    echo "🧹 Deleting stale node object ${node_name}..."
    kubectl delete node "${node_name}" --ignore-not-found
  fi
done

echo "✅ Remediation commands issued. Watch recovery with:"
echo "  kubectl get nodes -o wide"
