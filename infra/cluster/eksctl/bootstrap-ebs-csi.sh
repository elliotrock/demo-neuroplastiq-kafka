#!/usr/bin/env bash
set -euo pipefail

# Allow overriding via env; default to dev cluster/region.
CLUSTER_NAME="${CLUSTER_NAME:-neuro-dev}"
REGION="${AWS_REGION:-${REGION:-ap-southeast-2}}"
ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}"
ADDON_NAME="aws-ebs-csi-driver"
TRUST_DOC="$(mktemp)"

echo "🔧 Enabling AWS EBS CSI Add-on for EKS cluster: $CLUSTER_NAME in $REGION"

# Ensure OIDC provider exists (idempotent if already associated)
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$REGION" --approve

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_PROVIDER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.identity.oidc.issuer" --output text | sed 's#https://##')"

cat > "$TRUST_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create IAM role for the EBS CSI driver (if not existing)
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "📌 Creating IAM Role for EBS CSI driver…"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://"$TRUST_DOC"
fi

echo "📌 Ensuring IAM Role trust policy is up to date…"
aws iam update-assume-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-document file://"$TRUST_DOC"

rm -f "$TRUST_DOC"

echo "📌 Attaching required IAM policy to EBS CSI Driver Role…"
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy || true

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

get_status() {
  aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --region "$REGION" \
    --query "addon.status" \
    --output text 2>/dev/null || echo "NONE"
}

log_addon_snapshot() {
  echo "Addon snapshot:"
  aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --region "$REGION" \
    --query "addon.{status:status,version:addonVersion,modifiedAt:modifiedAt,healthIssues:health.issues}" \
    --output json 2>/dev/null || echo "  describe-addon failed"
}

latest_update_id() {
  aws eks list-updates \
    --name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --region "$REGION" \
    --query "updateIds[-1]" \
    --output text 2>/dev/null || echo "None"
}

log_latest_update() {
  local id
  id="$(latest_update_id)"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "No addon update id available."
    return 0
  fi
  echo "Latest addon update ($id):"
  aws eks describe-update \
    --name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --region "$REGION" \
    --update-id "$id" \
    --query "update.{status:status,type:type,createdAt:createdAt,errors:errors}" \
    --output json 2>/dev/null || echo "  describe-update failed for $id"
}

log_kube_addon_diagnostics() {
  echo "kube-system addon diagnostics:"
  kubectl -n kube-system get pods -o wide 2>/dev/null | grep -E 'ebs-csi|coredns|NAME' || true
  kubectl -n kube-system get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 || true
}

wait_ready() {
  local tries=60
  local delay=10
  for attempt in $(seq 1 "$tries"); do
    local s
    s="$(get_status)"
    case "$s" in
      ACTIVE|NONE)
        return 0
        ;;
      FAILED|CREATE_FAILED|UPDATE_FAILED)
        echo "Addon status $s; aborting."
        log_addon_snapshot
        log_latest_update
        log_kube_addon_diagnostics
        return 1
        ;;
      DEGRADED)
        echo "Addon status DEGRADED; waiting for recovery..."
        sleep "$delay"
        ;;
      *)
        echo "Addon status $s; waiting..."
        sleep "$delay"
        ;;
    esac
    if [ $((attempt % 6)) -eq 0 ]; then
      log_addon_snapshot
      log_latest_update
    fi
  done
  echo "Timed out waiting for addon to become ready."
  log_addon_snapshot
  log_latest_update
  log_kube_addon_diagnostics
  return 1
}

log_nodegroups() {
  echo "Nodegroup status snapshot:"
  local ngs
  ngs="$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --output text 2>/dev/null || true)"
  if [ -z "$ngs" ]; then
    echo "  (no nodegroups returned)"
    return 0
  fi
  for ng in $ngs; do
    aws eks describe-nodegroup \
      --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$ng" \
      --region "$REGION" \
      --query '{name:nodegroup.nodegroupName,status:nodegroup.status,health:nodegroup.health,scaling:nodegroup.scalingConfig,asg:nodegroup.resources.autoScalingGroups}' \
      --output json 2>/dev/null || echo "  describe failed for $ng"
  done
}

log_cluster_status() {
  echo "Cluster status snapshot:"
  aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query '{name:cluster.name,status:cluster.status,version:cluster.version,endpoint:cluster.endpoint,health:cluster.health}' \
    --output json 2>/dev/null || echo "  describe-cluster failed"
}

log_cfn_stack() {
  local name="$1"
  aws cloudformation describe-stacks \
    --stack-name "$name" \
    --region "$REGION" \
    --query 'Stacks[0].{StackName:StackName,Status:StackStatus,Reason:StackStatusReason,LastUpdated:LastUpdatedTime}' \
    --output json 2>/dev/null || true
}

log_cfn_events() {
  local name="$1"
  echo "Recent CloudFormation events for $name:"
  aws cloudformation describe-stack-events \
    --stack-name "$name" \
    --region "$REGION" \
    --max-items 15 \
    --query 'reverse(StackEvents)[*].{Time:Timestamp,Status:ResourceStatus,Type:ResourceType,LogicalId:LogicalResourceId,StatusReason:ResourceStatusReason}' \
    --output table 2>/dev/null || true
}

log_stack_summaries() {
  echo "CloudFormation stacks (eksctl*):"
  aws cloudformation list-stacks \
    --region "$REGION" \
    --query 'StackSummaries[?contains(StackName, `eksctl-`)].{Name:StackName,Status:StackStatus,Reason:StackStatusReason,LastUpdated:LastUpdatedTime}' \
    --output table 2>/dev/null || true
}

log_eksctl_nodegroups() {
  echo "eksctl get nodegroup output:"
  eksctl get nodegroup --cluster "$CLUSTER_NAME" --region "$REGION" 2>/dev/null || true
}

wait_for_nodes() {
  local tries=60
  local delay=10
  for attempt in $(seq 1 "$tries"); do
    # Count Ready nodes; suppress errors if cluster is still starting
    local ready
    ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {count++} END {print count+0}')"
    ready="${ready:-0}"
    if [ "$ready" -gt 0 ]; then
      echo "Cluster has $ready Ready node(s); proceeding with addon."
      return 0
    fi
    echo "Waiting for nodes to become Ready... (attempt $attempt/$tries)"
    kubectl get nodes -o wide --no-headers 2>/dev/null || echo "kubectl get nodes not yet available"
    if [ $((attempt % 6)) -eq 0 ]; then
      log_nodegroups
      log_eksctl_nodegroups
      log_stack_summaries
      log_cluster_status
      log_cfn_stack "eksctl-${CLUSTER_NAME}-cluster"
      log_cfn_stack "eksctl-${CLUSTER_NAME}-nodegroup-ng-spot"
      log_cfn_events "eksctl-${CLUSTER_NAME}-nodegroup-ng-spot"
    fi
    sleep "$delay"
  done
  echo "Timed out waiting for Ready nodes."
  log_cfn_events "eksctl-${CLUSTER_NAME}-nodegroup-ng-spot"
  log_cfn_events "eksctl-${CLUSTER_NAME}-cluster"
  return 1
}

wait_deleted() {
  local tries=60
  local delay=10
  for attempt in $(seq 1 "$tries"); do
    local s
    s="$(get_status)"
    case "$s" in
      NONE)
        return 0
        ;;
      *)
        echo "Addon status $s during delete; waiting..."
        sleep "$delay"
        ;;
    esac
    if [ $((attempt % 6)) -eq 0 ]; then
      log_addon_snapshot
      log_latest_update
    fi
  done
  echo "Timed out waiting for addon to delete."
  log_addon_snapshot
  log_latest_update
  log_kube_addon_diagnostics
  return 1
}

create_addon() {
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --service-account-role-arn "$ROLE_ARN" \
    --region "$REGION"
}

update_addon_once() {
  aws eks update-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --service-account-role-arn "$ROLE_ARN" \
    --region "$REGION"
}

echo "🚀 Ensuring EBS CSI Add-on is installed…"
wait_for_nodes
status="$(get_status)"
if [ "$status" = "NONE" ]; then
  echo "Addon not found; creating…"
  create_addon
  created="yes"
else
  created="no"
  if [ "$status" != "ACTIVE" ]; then
    echo "Addon status $status; waiting for it to settle before updating…"
    if ! wait_ready; then
      echo "Addon stuck in $status; deleting and recreating..."
      aws eks delete-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$ADDON_NAME" \
        --region "$REGION" || true
      wait_deleted
      create_addon
      status="NONE"
      created="yes"
    fi
  fi
  # Attempt update; if in-use, wait once and retry.
  if [ "$created" = "no" ]; then
    if ! update_addon_once; then
      echo "Addon update blocked (possibly in progress); waiting and retrying once..."
      wait_ready
      if ! update_addon_once; then
        echo "Addon update still blocked; deleting and recreating..."
        aws eks delete-addon \
          --cluster-name "$CLUSTER_NAME" \
          --addon-name "$ADDON_NAME" \
          --region "$REGION" || true
        wait_deleted
        create_addon
        created="yes"
      fi
    fi
  fi
fi

wait_ready
echo "✅ EBS CSI Driver installed successfully."
