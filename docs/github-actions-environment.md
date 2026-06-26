# GitHub Actions Environment Inventory

Date: 2026-06-23

## Purpose

This document records the GitHub Actions environment variables and secrets needed by the demo deployment path. It intentionally records names and usage only, not secret values.

The demo currently keeps the previously working staging deployment workflow:

```text
.github/workflows/deploy-staging.yml
```

That workflow now triggers from `main`, but it still deploys the known staging-shaped infrastructure and uses the GitHub Environment named `staging`.

## Active GitHub Environment

```text
staging
```

The workflow currently declares:

```yaml
environment:
  name: staging
```

## Existing Staging Secrets/Variables

The current GitHub Environment contains these names:

```text
AWS_ROLE_ARN
BEDROCK_API_KEY
CONFLUENT_LICENSE_KEY
EKS_CLUSTER_NAME
SCHEMA_REGISTRY_API_KEY
SCHEMA_REGISTRY_SECRET
SNOWFLAKE_PRIVATE_KEY
SNOWFLAKE_PRIVATE_KEY_P8
SNOWFLAKE_USERNAME
```

## Required for Current Demo Deployment

### `AWS_ROLE_ARN`

Status: required.

Used directly by `.github/workflows/deploy-staging.yml`:

```yaml
role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
```

Purpose:

- Allows GitHub Actions to assume the AWS deploy role through OIDC.
- Deploys CloudFormation network/API stacks.
- Creates or updates the EKS cluster and nodegroups.
- Configures kubeconfig.
- Deploys Confluent Platform with Helm.
- Publishes connector plugin artifacts to S3.

Use the existing staging value for the first demo deployment pass.

Expected format:

```text
arn:aws:iam::<account-id>:role/<role-name>
```

Do not set this to only the role name. `aws-actions/configure-aws-credentials` will fail with:

```text
Source Account ID is needed if the Role Name is provided and not the Role Arn.
```

For the current copied staging setup, this should be the full ARN for the existing GitHub Actions staging deploy role.

## Existing Values Not Currently Used by the Active Workflow

### `BEDROCK_API_KEY`

Status: required when the demo deploys or exercises `neuroplastiq-core` features that call Bedrock.

No active reference was found in the retained infrastructure deployment workflow itself, but this key is used by `neuroplastiq-core`. Keep the existing staging value available for any demo path that deploys the core API/control-plane or runs core workflows that call Bedrock.

### `CONFLUENT_LICENSE_KEY`

Status: not currently used by the active workflow.

The current Helm values use Confluent development licensing semantics in chart values. No direct `${{ secrets.CONFLUENT_LICENSE_KEY }}` reference was found in the active workflow.

If the demo later needs an enterprise Confluent license, wire this deliberately into the Helm values rather than relying on it being present in GitHub.

### `EKS_CLUSTER_NAME`

Status: present in GitHub environment, but not currently used by the active workflow.

The retained workflow currently hard-codes:

```text
CLUSTER_NAME=neuro-staging
```

Do not change this for the first pass if the goal is to preserve the known-working staging deployment mechanics. Later, this should be converted to a GitHub Environment variable and renamed for the demo cluster.

### `SCHEMA_REGISTRY_API_KEY`

Status: not currently used.

The active Kafka/Schema Registry deployment appears to use in-cluster Schema Registry connectivity, not Confluent Cloud API-key authentication.

### `SCHEMA_REGISTRY_SECRET`

Status: not currently used.

Same status as `SCHEMA_REGISTRY_API_KEY`; keep it out of the demo path unless Schema Registry auth is deliberately introduced.

## Values Not Needed for Now

The following are not needed for the current Kafka demo direction and should not be required for the first deployment pass:

```text
SNOWFLAKE_PRIVATE_KEY
SNOWFLAKE_PRIVATE_KEY_P8
SNOWFLAKE_USERNAME
```

The active deployment workflow no longer publishes connector plugin ZIPs, mounts the Snowflake private key, or applies Snowflake connector configs. Snowflake material may still exist in copied reference files, but it is intentionally outside the demo deployment path.

## Hard-Coded Current Workflow Values

The active workflow currently hard-codes these non-secret values:

```text
AWS_REGION=ap-southeast-2
CLUSTER_NAME=neuro-staging
STAGING_NODEGROUP_NAME=ng-medium
STAGING_NODEGROUP_MIN_SIZE=4
STAGING_NODEGROUP_DESIRED_SIZE=4
STAGING_NODEGROUP_MAX_SIZE=4
STAGING_CONFLUENT_NODEGROUPS="ng-confluent-2a ng-confluent-2b"
STAGING_CONFLUENT_NODEGROUP_SIZE=2
```

It also still references these staging resource names:

```text
neuro-staging-network
neuro-staging-api-gateway
EnvironmentName=staging
ApiNamePrefix=neuro
```

These are intentionally left unchanged for now to reduce deployment risk.

## Future Demo Values

When there is time to move away from the copied staging resource names, introduce new demo-specific values:

```text
GitHub Environment=demo
CLUSTER_NAME=demo-neuroplastiq-kafka
network stack=demo-neuroplastiq-kafka-network
api stack=demo-neuroplastiq-kafka-api-gateway
EnvironmentName=demo
ApiNamePrefix=neuroplastiq-demo
```

At that point, `EKS_CLUSTER_NAME` can replace the hard-coded `CLUSTER_NAME`, but that should be a deliberate workflow change after the current path is proven in the new repo.
