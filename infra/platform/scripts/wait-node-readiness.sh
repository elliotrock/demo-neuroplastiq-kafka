#!/usr/bin/env bash
set -euo pipefail

EXPECTED_READY="${1:-${EXPECTED_READY_NODES:-3}}"
TIMEOUT_SECONDS="${2:-${NODE_READY_TIMEOUT:-900}}"
NODE_SELECTOR="${3:-${NODE_READY_SELECTOR:-}}"

KUBECTL_SELECTOR_ARGS=()
if [[ -n "${NODE_SELECTOR}" ]]; then
  KUBECTL_SELECTOR_ARGS=(-l "${NODE_SELECTOR}")
fi

deadline=$((SECONDS + TIMEOUT_SECONDS))
attempt=0

print_debug_snapshot() {
  echo "--- node snapshot ---"
  kubectl get nodes "${KUBECTL_SELECTOR_ARGS[@]}" -o wide || true
  kubectl get nodes "${KUBECTL_SELECTOR_ARGS[@]}" -o jsonpath='{range .items[*]}{.metadata.name}{" | taints="}{.spec.taints}{" | conditions="}{range .status.conditions[*]}{.type}={.status}:{.reason};{end}{"\n"}{end}' || true

  echo "--- recent cluster events ---"
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 || true

  echo "--- kube-system pods (networking/storage) ---"
  kubectl -n kube-system get pods -o wide | grep -E 'aws-node|coredns|ebs|csi|kube-proxy' || true
}

while true; do
  attempt=$((attempt + 1))
  total_nodes="$(kubectl get nodes "${KUBECTL_SELECTOR_ARGS[@]}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  ready_nodes="$(kubectl get nodes "${KUBECTL_SELECTOR_ARGS[@]}" --no-headers 2>/dev/null | awk '$2=="Ready"{count++} END{print count+0}')"
  unreachable_nodes="$(
    kubectl get nodes "${KUBECTL_SELECTOR_ARGS[@]}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.taints}{"\n"}{end}' 2>/dev/null \
      | grep -c 'node.kubernetes.io/unreachable' || true
  )"

  echo "node readiness: attempt=${attempt} selector=${NODE_SELECTOR:-all} total=${total_nodes} ready=${ready_nodes} expected=${EXPECTED_READY} unreachable_taints=${unreachable_nodes}"

  if [[ "${ready_nodes}" -ge "${EXPECTED_READY}" && "${unreachable_nodes}" -eq 0 ]]; then
    echo "Node readiness gate passed."
    exit 0
  fi

  if (( attempt % 3 == 0 )); then
    print_debug_snapshot
  fi

  if (( SECONDS >= deadline )); then
    echo "Node readiness gate failed after ${TIMEOUT_SECONDS}s."
    echo "If unreachable nodes remain, remediate manually:"
    echo "  APPLY=1 infra/cluster/eksctl/remediate-unreachable-nodes.sh <cluster-name> <aws-region>"
    print_debug_snapshot
    exit 1
  fi

  sleep 20
done
