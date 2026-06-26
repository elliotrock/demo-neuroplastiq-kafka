# Phase 1 Cleanup

Date: 2026-06-22

## Purpose

Phase 1 converts the copied infra tree into a clearly scoped Kafka demo repo. The goal is not to finish the whole refactor in one pass; it is to stop the repo from presenting itself as Neuro production infrastructure and to separate obvious demo assets from copied production or product-code assets.

## Completed in this pass

- Replaced the copied Neuro README with a demo-specific README.
- Added this cleanup log under `docs/`.
- Hardened `.gitignore` for Python, Node, Terraform, Helm dependency archives, local secrets, generated files, and Windows metadata sidecars.
- Kept the copied staging deployment workflow as the demo deployment path and changed its push trigger from `staging` to `main` to preserve the known-working deployment mechanics under time constraints.
- Removed clearly accidental/generated files:
  - `*:Zone.Identifier`
  - `costs_01_26.csv`
  - `10`
  - `infra/cloudformation/--*` command-fragment files

## Keep for now

These paths remain because they may contain useful demo material, but they need review before the first clean commit:

```text
infra/platform/charts/confluent-platform/
infra/platform/scripts/
infra/platform/environments/dev/
confluent/
services/neuroplastiq/k8s/
```

## Quarantine candidates

These paths are copied from the source infra tree but likely do not belong in the final Kafka demo baseline:

```text
app/
core/
snowflake/
infra/cluster/eksctl/cluster-staging.yaml
infra/cluster/eksctl/cluster-prod.yaml
infra/terraform/snowflake/
.github/workflows/deploy-prod.yml
```

Do not delete these blindly if they contain useful examples. Either move them to `docs/reference/`, replace them with demo-safe examples, or remove them once the Kafka demo path is working.

## Next actions

1. Create `environments/local/` and `environments/cloud-demo/`.
2. Move the demo Kafka values out of `infra/platform/environments/dev/` into the new environment shape.
3. Rename or wrap smoke scripts under top-level `scripts/`.
4. Remove unused production deploy workflows from the demo repo after confirming no reusable CI logic is needed.
5. Move product code references to image/config contracts instead of keeping copied `app/` and `core/` code.
6. Decide whether Snowflake remains as a later optional demo or moves to a separate `demo-neuroplastiq-snowflake-sink` repo.
