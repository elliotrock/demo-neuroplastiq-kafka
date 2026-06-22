## Neuroplastiq (staging)

Kubernetes manifests live in `services/neuroplastiq/k8s/`.

### Apply

```bash
kubectl apply -f services/neuroplastiq/k8s/namespace.yaml
kubectl apply -f services/neuroplastiq/k8s/secret.yaml
kubectl apply -f services/neuroplastiq/k8s/deployment.yaml
kubectl apply -f services/neuroplastiq/k8s/service.yaml
kubectl apply -f services/neuroplastiq/k8s/graphql-source-workers-phase1.yaml
kubectl apply -f services/neuroplastiq/k8s/control-plane-cronjobs.yaml
```

### Notes

- Update `services/neuroplastiq/k8s/deployment.yaml` with the ECR image URI.
- Update `services/neuroplastiq/k8s/graphql-source-workers-phase1.yaml` with the same ECR image URI.
- Update `services/neuroplastiq/k8s/control-plane-cronjobs.yaml` with the same ECR image URI.
- Update `services/neuroplastiq/k8s/secret.yaml` with the real Postgres URL.
- Update `SCHEMA_REGISTRY_URL` to the internal NLB DNS.
- `control-plane-cronjobs.yaml` runs one hourly scheduler CronJob with
  `concurrencyPolicy: Forbid`; it runs `master-daily.yaml` at 02:00
  Australia/Sydney and `master-hourly.yaml` at the other hourly ticks.
- Neuroplastiq integration feature docs live in `/home/elliotrock/Development/poc-neuroplastiq-data/docs/`:
  - `/home/elliotrock/Development/poc-neuroplastiq-data/docs/graphql-source-sharding-rollout.md`
  - `/home/elliotrock/Development/poc-neuroplastiq-data/docs/filter-index-contract.md`
- Canonical Neuro Registry DDL/migrations live in `/home/elliotrock/Development/poc-neuroplastiq-data/db/neuro-registry/migrations/`.
