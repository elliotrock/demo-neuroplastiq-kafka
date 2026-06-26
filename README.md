# Demo Neuroplastiq Kafka

`demo-neuroplastiq-kafka` is a demo repository for proving a Kafka-backed Neuroplastiq deployment pattern. It is intentionally separate from `neuroplastiq-infra` so demo-specific configuration, sample data, shortcuts, and reset scripts do not leak into the reusable SaaS infrastructure repo.

This repo was seeded from the previous Neuro platform infrastructure tree. Phase 1 is focused on ownership cleanup: keeping the Kafka/Confluent deployment assets that are useful for a demo, removing generated/local material, and clearly marking copied production-oriented assets before they are either simplified or deleted.

## Demo Goals

- Run a small Kafka and Schema Registry setup suitable for Neuroplastiq demos.
- Provide a repeatable path for deploying the demo locally or into a low-cost cloud environment.
- Exercise Neuroplastiq product images from `neuroplastiq-core`, `neuroplastiq-portal`, and `neuroplastiq-connectors` without building those products here.
- Keep sample topics, schemas, connector configs, and smoke checks close to the demo.
- Make teardown and reset paths obvious.

## Non-Goals

- This is not the production SaaS infrastructure repo.
- This repo should not own reusable product source code.
- This repo should not carry Neuro-specific tenant configuration.
- This repo should not define staging or production environments for Neuroplastiq SaaS.
- This repo should not publish connector images; that belongs in `neuroplastiq-connectors`.

## Current Seeded Assets

Useful demo candidates:

```text
infra/platform/charts/confluent-platform/   Confluent Platform Helm chart
infra/platform/scripts/                     Kafka and connector smoke/check scripts
infra/platform/environments/dev/            Existing dev values to simplify into demo values
confluent/                                  Connector, schema, and Kafka-related seed material
services/neuroplastiq/k8s/                  Temporary Neuroplastiq deployment references
```

Assets to review or remove during cleanup:

```text
app/                                        Copied application code; belongs in product repos
core/                                       Copied control-plane code; belongs in neuroplastiq-core
snowflake/ and root Snowflake SQL           Optional demo dependency, not Kafka baseline
infra/cluster/eksctl/cluster-prod.yaml      Production cluster config, not demo baseline
infra/cluster/eksctl/cluster-staging.yaml   Staging cluster config, not demo baseline
.github/workflows/deploy-*.yml              Copied production-style deploy workflows
```

## Intended Shape

Target structure after cleanup:

```text
demo-neuroplastiq-kafka/
  README.md
  docs/
    phase-1-cleanup.md
    walkthrough.md
    architecture.md
  environments/
    local/
      values.yaml
    cloud-demo/
      values.yaml
  kafka/
    topics.yaml
    schemas/
    sample-events/
  neuroplastiq/
    connector-configs/
    registry-seeds/
    control-plane-plans/
  scripts/
    up.sh
    smoke.sh
    reset.sh
    down.sh
  helm/
```

## Phase 1 Status

Phase 1 has started. See `docs/phase-1-cleanup.md` for the cleanup log and next actions.
