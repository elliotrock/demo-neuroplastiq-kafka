# Context Log

Use this file for short, append-only notes that capture decisions, debugging state, and next steps.
Keep entries brief and date-stamped.

## Template

- YYYY-MM-DD – short summary
  - key detail 1
  - key detail 2

## 2025-12-23 – Confluent smoke checks + local context tooling

- Kafka broker crashloop was due to `inter.broker.listener.name=REPLICATION` missing in `advertised.listeners`; fixed in:
  - `infra/platform/charts/confluent-platform/templates/kafka.yaml`
  - `infra/platform/confluent-platform-dev.yaml`
- Smoke checks fixes:
  - `kubectl run` uses `--rm --attach --command` in `infra/platform/scripts/smoke-kafka-verify.sh`
  - Cleanup Succeeded pods before waiting for readiness in `infra/platform/scripts/smoke-checks.sh`
- Connect crashloop caused by replication factor 3 on single-broker dev; set to 1 in:
  - `infra/platform/charts/confluent-platform/templates/connect.yaml`
  - `infra/platform/confluent-platform-dev.yaml`
- Local context tools added in `tools/context/` (context log + SQLite FTS index scripts).
