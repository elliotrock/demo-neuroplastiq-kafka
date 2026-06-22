# Handoff Notes (bookibet-platform)

## 2026-02-16 – Bookibet platform updates (connector CI/CD + reset helpers)

- Summary:
  - Main deployment blockers were narrowed down to stale internal topic state and smoke-test topic creation behavior, not plugin packaging.
  - Cluster reached healthy 3-broker Ready state and connector runtime came up; remaining failures were pipeline/script logic issues.

- Connector CI/CD hardening completed:
  - `infra/platform/scripts/apply-and-verify-connectors.sh`
    - Added Connect internal-topic preflight validation for:
      - `connect-configs`
      - `connect-offsets`
      - `connect-statuses`
    - Added optional non-prod auto-repair path:
      - scale connect down
      - delete stale connect internal topics
      - scale connect up
      - wait ready and continue
    - Added env flags:
      - `CONNECT_INTERNAL_TOPIC_AUTOREPAIR` (default `false`)
      - `CONNECT_INTERNAL_TOPIC_RF_TARGET` (default `3`)
      - `CONNECT_BOOTSTRAP_SERVER` (default `kafka.confluent.svc.cluster.local:9092`)
      - `CONNECT_WAIT_RESTART_THRESHOLD` (default `2`)
    - Added robust diagnostics:
      - pod/statefulset status
      - pod describe tail
      - connect logs + previous logs
      - filtered error grep
      - recent namespace events
      - topic state dump for connect topics and `__consumer_offsets`
    - Added progress logging during connect readiness waits (phase/restarts/waitingReason) and fail-fast on crashloop/restart threshold.
    - Fixed topic deletion compatibility: delete one topic per `kafka-topics --delete` invocation (CLI in this image accepts one `--topic`).
  - `.github/workflows/deploy-staging.yml`
    - Enabled `CONNECT_INTERNAL_TOPIC_AUTOREPAIR: "true"` in connector apply step.
    - Removed separate early plugin-check step that was timing out before repair path could run.

- Smoke test fix completed:
  - `infra/platform/scripts/smoke-kafka-verify.sh`
    - Removed hardcoded smoke topic RF=1.
    - Smoke topic replication factor now auto-detects from ready broker count (caps at 3), preventing false failures with cluster `min.insync.replicas=2`.
    - This addressed observed `NotEnoughReplicasException` on smoke topic produce.

- Non-prod reset helper added to Makefile:
  - `makefile`
    - New target: `confluent-reset-nonprod`
      - Destructive reset of CFK CRs and PVCs in namespace.
      - Requires explicit `CONFIRM=YES`.
    - New target: `confluent-verify-offsets`
      - Post-redeploy check for `__consumer_offsets`.
    - Added inline warning and use-case comments.
  - Example:
    - `CONFIRM=YES NAMESPACE=confluent KUBE_CONTEXT=<context> make confluent-reset-nonprod`
    - redeploy via pipeline/helm
    - `NAMESPACE=confluent KUBE_CONTEXT=<context> make confluent-verify-offsets`

- Important operational context:
  - Helm values are set correctly for new deployments (RF=3 / minISR=2), but existing topics created earlier at RF=1 are not retroactively fixed by `helm upgrade`.
  - Clean non-prod reset/redeploy is the fastest path to align internal topic shape with current policy.

## 2026-02-16 – Kafka internal topic drift + Connect/SR timeouts (staging)

- Summary:
  - Staging had repeated connector apply timeouts and Schema Registry crash loops even when pods were `Running`.
  - Root cause was stale Kafka internal topics created long ago at `ReplicationFactor=1` but now running with stricter configs (e.g. `min.insync.replicas=2` on Connect topics).
  - This produced:
    - `NotEnoughReplicasException` / `COORDINATOR_NOT_AVAILABLE` on `__consumer_offsets`
    - `ListenerNotFoundException`/metadata retries in Connect
    - connector REST apply timing out (`curl: (28)`).

- Key evidence:
  - `__consumer_offsets` showed `ReplicationFactor: 1` and all partitions on broker `0`.
  - `connect-configs/connect-offsets/connect-statuses` also showed `ReplicationFactor: 1` with `min.insync.replicas=2`.
  - Kafka logs showed repeated append failures to `__consumer_offsets-*` with insufficient ISR.

- Infra/code changes made:
  - Confirmed chart/env values are already correct for new deployments:
    - `infra/platform/environments/staging/values-staging.yaml`
      - `default.replication.factor: 3`
      - `min.insync.replicas: 2`
      - `offsets.topic.replication.factor: 3`
      - `transaction.state.log.replication.factor: 3`
      - Connect internal topic RFs set to `3`.
  - Added Connect internal-topic auto-repair before connector apply:
    - `infra/platform/scripts/apply-and-verify-connectors.sh`
      - preflight checks for `connect-configs/connect-offsets/connect-statuses`
      - detects stale topic shape (RF below target or minISR > RF)
      - optional auto-repair path: scale connect down, delete stale topics, scale up, wait ready
      - env controls:
        - `CONNECT_INTERNAL_TOPIC_AUTOREPAIR` (default `false`)
        - `CONNECT_INTERNAL_TOPIC_RF_TARGET` (default `3`)
        - `CONNECT_BOOTSTRAP_SERVER` (default `kafka.confluent.svc.cluster.local:9092`)
      - fixed topic delete behavior for Kafka CLI that accepts only one `--topic` per command.
  - Enabled auto-repair in staging CI:
    - `.github/workflows/deploy-staging.yml`
      - in "Apply connector configs and verify status" step:
        - `CONNECT_INTERNAL_TOPIC_AUTOREPAIR: "true"`

- Operational notes from incident:
  - `kafka-2` was previously `Pending` due to PVC node-affinity to a dead node; pod/PVC recreation unblocked scheduling.
  - This was not a VPC image-pull issue; scheduler reported anti-affinity + volume node affinity conflict.

- What is still manual / important:
  - Existing `__consumer_offsets` topic may still be RF=1 in already-provisioned clusters.
  - Helm values do not retroactively change existing topic replication.
  - For full durability parity, either:
    - clean redeploy (preferred for non-prod), or
    - run partition reassignment for `__consumer_offsets` (+ other internal topics as needed), then set minISR back to target.

- Quick verification commands:
  - `kubectl -n confluent exec kafka-0 -c kafka -- kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9092 --describe --topic 'connect-(offsets|configs|statuses)|__consumer_offsets'`
  - `kubectl -n confluent logs connect-0 --tail=200 | rg -i 'ListenerNotFoundException|COORDINATOR_NOT_AVAILABLE|NotEnoughReplicas'`
  - `kubectl -n confluent logs schemaregistry-0 --tail=200 | rg -i 'Timed out waiting for join group|COORDINATOR_NOT_AVAILABLE'`

## 2026-02-13 – Staging infra recovery: EBS CSI DEGRADED due to unreachable nodes

- Summary:
  - Kafka scale-up work exposed broader cluster instability; issue is not only Kafka config.
  - `aws-ebs-csi-driver` repeatedly stuck in `DEGRADED`/`UPDATE_FAILED`.
  - Root signal from addon health:
    - `InsufficientNumberOfReplicas`
    - `0/2 nodes are available: ... untolerated taint {node.kubernetes.io/unreachable}`
  - Recreating the addon alone does not resolve this while nodes remain tainted/unreachable.

- What was already done:
  - Ran `infra/cluster/eksctl/bootstrap-ebs-csi.sh` multiple times.
  - Script now prints richer diagnostics (addon snapshot, latest update, kube-system pod/events snapshot).
  - Addon delete/recreate path executes, but returns to `DEGRADED` with same node taint error.
  - Observed kube-system state included `ebs-csi-controller` pods pending/unscheduled and old terminating pods.

- Current conclusion:
  - Primary blocker is node health/scheduling (`node.kubernetes.io/unreachable` taint), not IAM role policy wiring.
  - Fix node readiness first, then addon/Kafka/Connect stabilization can proceed.

- Resume checklist (exact commands):
  - 1. Validate node state:
    - `kubectl get nodes -o wide`
    - `kubectl describe node ip-10-0-2-64.ap-southeast-2.compute.internal | tail -n 120`
    - `kubectl describe node ip-10-0-3-104.ap-southeast-2.compute.internal | tail -n 120`
  - 2. Validate addon + kube-system state:
    - `aws eks describe-addon --cluster-name bookibet-staging --addon-name aws-ebs-csi-driver --region ap-southeast-2`
    - `kubectl -n kube-system get pods -o wide | rg "ebs|csi|coredns"`
    - `kubectl -n kube-system get events --sort-by=.lastTimestamp | tail -n 80`
  - 3. Force cleanup of dead/stuck kube-system pods:
    - `kubectl -n kube-system delete pod -l app.kubernetes.io/name=aws-ebs-csi-driver --force --grace-period=0`
    - `kubectl -n kube-system delete pod -l k8s-app=kube-dns --force --grace-period=0`
  - 4. If nodes remain `NotReady`/`unreachable`, repair nodegroup capacity:
    - Scale nodegroup up by +1 (preferred), then cordon/drain/remove bad node(s), or recycle instances.
    - Re-check until all nodes show `Ready` and unreachable taint is gone.
  - 5. Re-run addon bootstrap only after node readiness is restored:
    - `bash infra/cluster/eksctl/bootstrap-ebs-csi.sh`
  - 6. Re-verify platform pods:
    - `kubectl -n confluent get pods -o wide`
    - `kubectl -n confluent get kafka,schemaregistry,connect -o wide`

- Optional temporary unblock:
  - If a deploy must proceed without new PV provisioning, skip/disable the EBS CSI bootstrap step in workflow for that run only.
  - Restore the step once node health is stable.

## 2026-01-21 – Kong Kafka REST v3-only routing + script sanity check

- Summary:
  - Standardized Kong routing on Kafka REST v3 only (avoid v2).
  - Updated the test/seed script to be v3-only and produce via the v3 records API.
- Changes:
  - `infra/kong/kong.yaml`: Kafka REST service base URL now includes `/v3`, and route is `/data/v3`.
  - `infra/platform/scripts/push-test-schema-and-payload.sh`: v3-only discovery (`/clusters`), v3 topic ops, v3 produce (`/records`), no v2 fallbacks.
- Next steps (testing):
  - Apply and restart Kong: `make kong-apply && kubectl -n kong rollout restart deploy/kong-kong`
  - Port-forward and test v3 endpoint:
    - `kubectl -n kong port-forward svc/kong-kong-proxy 18080:80`
    - `curl -i -H "apikey: bookibet-dev-key" http://localhost:18080/data/v3/clusters`
  - Run the script: `infra/platform/scripts/push-test-schema-and-payload.sh`
  - Capture and share outputs if anything fails:
    - `curl -i -H "apikey: bookibet-dev-key" http://localhost:18080/data/v3/clusters`
    - `infra/platform/scripts/push-test-schema-and-payload.sh` (success or error)

## 2026-01-22 – Kong route normalization + REST Proxy v3 test fixes (addendum)

- Summary:
  - Kept public route versionless (`/data`) while proxying to Kafka REST `/v3`.
  - Fixed Kong routing to match `/data/*` and pinned upstream to port 8082.
  - Updated test script defaults and payload to align with REST Proxy v3.
- Changes:
  - `infra/kong/kong.yaml`: Kafka REST service now explicitly uses `protocol/host/port/path` (avoids wrong service port), and `paths` uses regex `~^/data` to match `/data/*`.
  - `infra/platform/scripts/push-test-schema-and-payload.sh`: default route prefix is `/data`; improved `/clusters` debug output; avoid JSON parse on non-JSON; remove `type:"AVRO"` when using `schema_id`.
- Session context (staging):
  - Kong config on pod shows `/data` regex path; `/data/clusters` now returns 200 through Kong.
  - Direct REST Proxy path (`USE_KONG=0`) succeeds for topic create, schema register, and produce.

## 2026-01-23 – Kong routing mismatch (expressions router) investigation

- State:
  - Kong kept internal-only; port-forward used for access.
  - Port-forwarding to Kong sometimes drops after rollouts or pod replacement (`failed to find sandbox ...`); restarting the port-forward is required.
  - REST Proxy is healthy when accessed directly (`kubectl port-forward svc/kafka-rest 18082:8082` + `curl http://localhost:18082/v3/clusters` returns 200).
  - Kong intermittently returned 404 for `/data/*` and `/v3/*` paths; `/npf` also 404.
  - Switching to expressions router (`router_flavor: "expressions"`) loaded successfully.
  - Live config showed expression routes:
    - `http.path ~ "^/v3(/|$)"`
    - `http.path ~ "^/npf(/|$)"`
  - Temporary catch-all route (`expression: "true"`) routed successfully to Kafka REST (200).
- What is NOT the problem:
  - Kafka REST Proxy itself (direct curl is healthy).
  - Kong config loading (pod shows updated declarative config).
  - Kong auth headers (404 is “no route matched”, not auth failure).
- Likely causes:
  - Expressions router matching not behaving as expected with the current syntax/version.
  - Route expression operator nuances (`~` vs `^=`) or escaping issues.
  - Kong port-forward instability during rollouts (pod sandbox changes) can mask results but does not explain consistent 404 after stable pod.
- Suggested next steps:
  - Reintroduce a catch-all route temporarily and confirm stable 200 through Kong.
  - Try a minimal exact expression: `expression: 'http.path == "/v3/clusters"'` (single known path) to validate expression matching.
  - If exact match works, widen stepwise (`http.path ^= "/v3"`); otherwise consider reverting to traditional router with explicit regex paths and verify with `KONG_ROUTER_FLAVOR`.
  - Optionally enable Admin API (internal-only) to inspect routes via `/routes` for debugging, then disable again.
  - Keep Kong internal-only (ClusterIP + port-forward) until routing is stable.

## 2026-01-19 – Kong integration wiring + connector buffer tweaks

- Kong integration:
  - Added DB-less Kong config at `infra/kong/kong.yaml` with `/data` → Kafka REST (`kafka-rest.confluent.svc.cluster.local:8082`) and `/np` placeholder for NPF.
  - Added Helm values at `infra/kong/values-kong.yaml` (DB-less, ConfigMap mount, ClusterIP proxy).
  - Added `make kong-apply` target to create namespace/configmap and install Kong.
  - Wired Kong deployment into CI workflows:
    - `.github/workflows/deploy-dev.yml`
    - `.github/workflows/deploy-staging.yml`
    - `.github/workflows/deploy-prod.yml`
- Docs:
  - `bookibet-docs/kong_integration_plan.md` updated with `/data` route, staging steps, kong.yaml + values snippets, and clarified use cases.
- Snowflake connector (testing):
  - Buffering set to `buffer.count.records=1`, `buffer.flush.time=1`, `buffer.size.bytes=1000000` in `confluent/config/connectors/snowflake/snowflake-sink.json`.

Next steps:
- Deploy Kong via CI or `make kong-apply` once cluster access is confirmed.
- Update the `/np` upstream URL in `infra/kong/kong.yaml` when NPF is deployed (namespace/service/port).
- Decide on initial Kong auth credentials (key-auth/basic-auth) and add consumers/secrets if required.

## 2026-01-20 – Kong deploy unblocked + API flow notes

- Fixed Kong Helm values to use chart dblessConfig:
  - Removed `extraConfigMaps`/`extraVolumes`/`extraVolumeMounts` to avoid invalid mountPath error.
  - Added `dblessConfig` with `configMap: kong-config`, `configFile: kong.yaml`.
  - Kept `env.declarative_config` aligned to `/kong_dbless/kong.yaml`.
- Kong deploy succeeded (staging):
  - `helm -n kong status kong` shows deployed.
  - `pod/kong-kong` running.
  - `service/kong-kong-proxy` is `ClusterIP` (ports 80/443).
  - `service/kong-kong-manager` is `NodePort`; Admin API still disabled (manager not functional).

API flows (current):
- `/data` -> Kong proxy -> `kafka-rest.confluent.svc.cluster.local:8082` (Kafka REST).
- `/np` -> Kong proxy -> `neuroplastiq-api.default.svc.cluster.local:8000` (placeholder until NPF is deployed).

Notes/next:
- Proxy is internal-only while `ClusterIP` (use port-forward for local testing).
- If external access needed: switch proxy to `LoadBalancer` or front with Ingress/ALB and add DNS/TLS.

Example test commands:
- `helm -n kong status kong`
- `kubectl -n kong get pods,svc`
- `kubectl -n kong port-forward svc/kong-kong-proxy 8000:80`
- `curl -i http://localhost:8000/data`
- `curl -i http://localhost:8000/np`
- If auth enabled later:
  - Key-auth: `curl -H "apikey: <key>" http://localhost:8000/data`
  - Basic-auth: `curl -u user:pass http://localhost:8000/np`

## 2025-12-22 – Confluent stack still not healthy

- Changes made in repo:
  - Removed `advertised.listeners` from the KRaft controller template (CFK requires empty when `process.roles=controller`).
  - Added `kraftController` values blocks to base/dev/staging/prod and enabled the controller chart.
  - Smoke script now traps failures and dumps pods/describes/events for CI visibility.
- Current state in cluster (confluent ns):
  - `kafka-controller-0` running but never Ready (port 9074 refused), readiness probe failing.
  - `kafka` broker CR has 0 pods; service `kafka` does not exist, only controller service exists.
  - Schema Registry and Connect crashloop because `kafka.confluent.svc.cluster.local:9092` is unresolved/unreachable.
  - Smoke checks time out waiting for connect/controller/SR.
- Likely next steps to unblock:
  - Get controller healthy: inspect logs and status, possibly reset PVC if stale format:
    - `kubectl logs kafka-controller-0 -n confluent -c kafka-controller --tail=200`
    - If stuck, `kubectl delete pvc data0-kafka-controller-0 -n confluent` (wipes controller state) then restart pod.
  - Once controller Ready, broker should start via CR; confirm `kubectl get svc,endpoints -n confluent | grep kafka`.
  - Restart SR/Connect after broker service exists.
- Useful commands for resume:
  - `kubectl get pods -n confluent -o wide`
  - `kubectl logs schemaregistry-0 -n confluent`
  - `kubectl logs connect-0 -n confluent`
  - `kubectl get kafka -A -o yaml`
  - `kubectl describe pvc data0-kafka-controller-0 -n confluent`

Current state (deploy-dev):

- Nodegroup stack now succeeds; launch template IAM fixed (LT resources now use `arn:aws:ec2:ap-southeast-2:838869291259:launch-template/*` in the GitHub Actions role policy).
- kubectl access works via the `cli-admin` role (assumed from user Elliotrock with inline assume-role permission); kubeconfig regenerated without self-assume.
- VPC CNI enabled; nodes Ready.
- Network stack (`bookibet-dev-network`) now deployed via CFN in the pipeline with NAT + VPC endpoints; S3/ECR endpoints exist and STS endpoint output added. STS endpoint confirmed present.
- Remaining blocker: EBS CSI add-on still failing (crashloop) due to STS DNS/egress from pods. CoreDNS pods are 0/1 Ready; `nslookup` from a pod times out, so cluster DNS is broken.

Actions needed (make these IaC, not ad-hoc):
- Provide egress for node subnets:
  - Option A (simpler): NAT gateways for private subnets with `0.0.0.0/0` routes.
  - Option B (private): VPC endpoints in the cluster VPC:
    - Interface: `com.amazonaws.ap-southeast-2.sts`, `...ecr.api`, `...ecr.dkr`
    - Gateway: S3
    - Endpoint SG allows inbound 443 from worker/node SG (and CNI SG if separate); nodes allow outbound 443.
- Manage add-ons in IaC:
  - Create EBS CSI (`aws-ebs-csi-driver`) and VPC CNI as managed add-ons with `serviceAccountRoleArn=AmazonEKS_EBS_CSI_DriverRole` and a pinned version (e.g., `v1.53.0-eksbuild.1`).
- IAM hygiene:
  - Node instance role should include the three standard managed policies: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`.
  - EBS CSI driver role must have `AmazonEBSCSIDriverPolicy` attached (ensure via IaC).
  - GitHub Actions deploy role already updated to LT wildcard ARN; keep OIDC trust as-is.
- Cluster access: define access entries (or aws-auth) for roles/users that need kubectl (`cli-admin`, CI roles) instead of ad-hoc CLI grants.
- DNS/ST S debugging in progress:
  - CoreDNS pods currently 0/1 Ready; need logs/describe and restart (`kubectl -n kube-system rollout restart deploy coredns`) once AWS creds are refreshed.
  - From an in-cluster pod, `nslookup sts.ap-southeast-2.amazonaws.com` times out; resolve once CoreDNS is healthy and STS endpoint PDNS is working.
  - EBS CSI logs still show `AssumeRoleWithWebIdentity ... sts.ap-southeast-2.amazonaws.com: i/o timeout`; expected to clear after DNS fix.

Where to codify (examples):
- `infra/cluster/eksctl`: add `addons` entries for `vpc-cni` and `aws-ebs-csi-driver` with the driver role ARN; ensure `managedNodeGroups[].iam.attachPolicyARNs` include the three managed policies. VPC endpoints/NAT should be defined in Terraform/CFN and referenced here via VPC/subnet IDs.
- `infra/terraform` or `infra/cloudformation`: add NAT or the four endpoints above; add `AWS::EKS::Addon` resources (or Terraform aws_eks_addon) for VPC CNI and EBS CSI; ensure the EBS CSI IAM role and node IAM role policy attachments are managed here.
- `infra/cluster/eksctl/bootstrap-ebs-csi.sh`: keep for idempotent apply, but once add-ons are IaC-managed, this script can be simplified or skipped in CI.

Next steps:
- Implement NAT or STS/ECR/S3 endpoints in dev (then replicate to staging/prod).
- Add the EBS/VPC CNI add-ons and IAM attachments to IaC.
- Re-run `deploy-dev`; EBS CSI should go ACTIVE once STS/ECR/S3 are reachable.


## Next Steps;
The controller is still not healthy, so brokers never start and Connect/SR keep crashing on the missing kafka.* bootstrap.

What to check next (quick):

Controller logs: kubectl logs kafka-controller-0 -n confluent -c kafka-controller --tail=200
Controller CR status: kubectl get kraftcontroller kafka-controller -n confluent -o yaml
If logs show the same config error or a formatting/metadata mismatch, the data PVC may be holding stale state. You can reset it with:
kubectl delete pod kafka-controller-0 -n confluent (to force restart); if it still fails,
Delete the PVC to reformat: kubectl delete pvc data0-kafka-controller-0 -n confluent (this wipes controller state; only do it if you’re okay with re-forming the KRaft quorum).
Once the controller reports Ready, the Kafka broker should start, create the kafka service/endpoints, and then Schema Registry/Connect will stop crash-looping.

If you can share the controller logs, I can confirm whether a PVC reset is needed or if there’s another config issue.

## 2025-12-23 – Broker listener mismatch + smoke script fix

- Controller is Ready; broker was crashlooping after restart with:
  - `inter.broker.listener.name=REPLICATION` not present in `advertised.listeners` (fatal validation error).
  - `/opt/confluentinc/etc/kafka/kafka.properties` differed from `/mnt/config/shared/kafka.properties`.
- Fix applied in repo:
  - Added REPLICATION to broker `advertised.listeners`:
    - `infra/platform/charts/confluent-platform/templates/kafka.yaml`
    - `infra/platform/confluent-platform-dev.yaml`
- Action required after deploy:
  - Re-apply chart/CR and delete `kafka-0` to pick up updated config.
- Smoke checks failure in CI:
  - `kubectl run ... --rm` requires attach; fixed by adding `--attach --command` in:
    - `infra/platform/scripts/smoke-kafka-verify.sh`
- Outstanding:
  - Connect keeps retrying topic creation with replication factor 3; for single-broker dev set `config.storage.replication.factor`, `offset.storage.replication.factor`, `status.storage.replication.factor` to 1.

## 2025-12-23 – Smoke checks + Connect single-broker fixes

- Smoke checks were failing due to:
  - `kubectl wait --for=condition=Ready pod --all` hanging on Completed pods (e.g., `kafka-cli`).
  - `kubectl run --rm` usage without attach in older script.
- Fixes applied in repo:
  - Clean up Succeeded pods before wait: `infra/platform/scripts/smoke-checks.sh`
  - `kubectl run` uses `--rm --attach --command`: `infra/platform/scripts/smoke-kafka-verify.sh`
  - Connect single-broker replication factors set to 1:
    - `infra/platform/charts/confluent-platform/templates/connect.yaml`
    - `infra/platform/confluent-platform-dev.yaml`
- Current cluster symptoms:
  - Kafka controller and broker are Ready.
  - Connect crashlooping due to internal topic creation timeouts (replication factor mismatch).

## 2025-12-23 – CI/CD, env split, API Gateway baseline, README cleanup

- README fixes:
  - Mermaid diagram labels updated and flow updated to match actual workflows.
  - Added trigger matrix, infra-only repo scope note, and public access note (API Gateway only).
  - Repo structure updated to include per-env eksctl configs and API Gateway template.
- CI/CD changes:
  - Split staging/prod workflow into separate files:
    - `.github/workflows/deploy-staging.yml`
    - `.github/workflows/deploy-prod.yml`
  - Added API Gateway stack deploy to all env workflows.
  - Staging/prod workflows now include EKS create-if-missing + nodegroup ensure (copied from dev).
  - Smoke checks run on all env deployments.
- EKS/eksctl changes:
  - Replaced `infra/cluster/eksctl/cluster.yaml` with per-env configs:
    - `infra/cluster/eksctl/cluster-dev.yaml`
    - `infra/cluster/eksctl/cluster-staging.yaml`
    - `infra/cluster/eksctl/cluster-prod.yaml`
  - Staging and prod configs are identical (3-node minimum).
  - EBS CSI bootstrap role names are now per-cluster: `AmazonEKS_EBS_CSI_DriverRole-<cluster>`.
- Confluent platform sizing:
  - `infra/platform/charts/confluent-platform/values-staging.yaml` updated to match prod sizing (3 brokers, 3 SR, 3 Connect, increased storage/resources).
- New CloudFormation:
  - `infra/cloudformation/api-gateway.yml` adds a minimal REST API with `/health` mock response.

## 2025-12-23 – End of day recap

- Work completed:
  - Separate deploy workflows for dev, staging, prod with smoke tests in all envs.
  - Per-environment `eksctl` configs added; staging/prod identical and sized for 3 brokers.
  - Staging Helm values updated to match prod sizing.
  - Minimal API Gateway stack added; only public entrypoint is API Gateway.
  - README updated for infra-only scope, flow diagram, trigger matrix, and API Gateway notes.
- Tomorrow’s start:
  - Verify AWS account ID in EBS CSI role ARNs inside `infra/cluster/eksctl/cluster-*.yaml`.
  - Confirm staging/prod nodegroup sizing if different from current defaults.
- Decide on API Gateway routing target (Kafka HTTP Connect, VPC Link) and auth pattern.

## 2025-12-24 – Staging/Prod pipeline context (from today)

- CI/CD split already done:
  - `.github/workflows/deploy-staging.yml`
  - `.github/workflows/deploy-prod.yml`
  - Both are based on dev and include: EKS create-if-missing + nodegroup ensure, API Gateway deploy, smoke checks.
- EKS configs split per env:
  - `infra/cluster/eksctl/cluster-dev.yaml`
  - `infra/cluster/eksctl/cluster-staging.yaml`
  - `infra/cluster/eksctl/cluster-prod.yaml`
  - Staging/prod are identical (3-node minimum).
- Confluent sizing aligned:
  - `infra/platform/charts/confluent-platform/values-staging.yaml` matches prod sizing (3 brokers, 3 SR, 3 Connect, larger storage/resources).
- API Gateway baseline:
  - `infra/cloudformation/api-gateway.yml` adds minimal REST API with `/health` mock response.

Open items for tomorrow:
- Verify AWS account ID in EBS CSI role ARNs inside `infra/cluster/eksctl/cluster-*.yaml`.
- Confirm staging/prod nodegroup sizing if different from defaults.
- Decide API Gateway routing target and auth pattern (Kafka HTTP Connect, VPC Link, etc.).

## 2025-12-24 – Snowflake connector env nuance (staging first)

- Snowflake connector should target staging first; align config to `BOOKIBET_STAGING.RAW`, `WH_INGEST_STAGING`, and role `KAFKA_CONNECT_ROLE_STAGING`.
- Current staging user grant is to `NICKSCOTT3` (role `KAFKA_CONNECT_ROLE_STAGING`), so connector user should match unless a dedicated service user is created.
- File to update: `confluent/config/connectors/snowflake/snowflake-sink.json`.
- Nuance: we have 3 envs (dev/staging/prod); decide whether to split connector configs per env or template a single file.

## 2026-01-14 – Snowflake connector auth + staging cleanup (Option 1)

- Root cause: connector config uses `snowflake.user.name = NICKSCOTT3` but RSA public key is registered on `KAFKA_CONNECT_DEV`, so Snowflake key-pair auth fails (`Cannot connect to Snowflake`).
- Decision: use a dedicated staging service user (tidier). Target user: `KAFKA_CONNECT_STAGING`.
- Connector should stay on staging targets: `BOOKIBET_STAGING.RAW`, `WH_INGEST_STAGING`, role `KAFKA_CONNECT_ROLE_STAGING`, account `EKLSXAU-ZC86838`.

SQL to align staging (create user + attach key + grants):

```
CREATE USER IF NOT EXISTS KAFKA_CONNECT_STAGING
  LOGIN_NAME = 'KAFKA_CONNECT_STAGING'
  DISPLAY_NAME = 'Kafka Connect STAGING'
  DEFAULT_ROLE = KAFKA_CONNECT_ROLE_STAGING
  DEFAULT_WAREHOUSE = WH_INGEST_STAGING
  DEFAULT_NAMESPACE = BOOKIBET_STAGING.RAW
  MUST_CHANGE_PASSWORD = FALSE;

ALTER USER KAFKA_CONNECT_STAGING
  SET RSA_PUBLIC_KEY_2='MIIBIjANB...IDAQAB';

GRANT ROLE KAFKA_CONNECT_ROLE_STAGING TO USER KAFKA_CONNECT_STAGING;
```

Reference SQL fragments currently in use (not uniform):

```
CREATE USER IF NOT EXISTS KAFKA_CONNECT_DEV
  LOGIN_NAME = 'KAFKA_CONNECT_DEV'
  DISPLAY_NAME = 'Kafka Connect DEV'
  DEFAULT_ROLE = ROLE_KAFKA_DEV
  DEFAULT_WAREHOUSE = WH_DEV
  DEFAULT_NAMESPACE = BOOKIBET_DEV.RAW
  MUST_CHANGE_PASSWORD = FALSE;

CREATE DATABASE BOOKIBET_STAGING;
CREATE SCHEMA BOOKIBET_STAGING.RAW;
CREATE WAREHOUSE WH_INGEST_STAGING
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
CREATE ROLE KAFKA_CONNECT_ROLE_STAGING;
GRANT USAGE ON WAREHOUSE WH_INGEST_STAGING TO ROLE KAFKA_CONNECT_ROLE_STAGING;
GRANT USAGE ON DATABASE BOOKIBET_STAGING TO ROLE KAFKA_CONNECT_ROLE_STAGING;
GRANT USAGE ON SCHEMA BOOKIBET_STAGING.RAW TO ROLE KAFKA_CONNECT_ROLE_STAGING;
GRANT CREATE TABLE, INSERT, SELECT ON SCHEMA BOOKIBET_STAGING.RAW TO ROLE KAFKA_CONNECT_ROLE_STAGING;
GRANT ROLE KAFKA_CONNECT_ROLE_STAGING TO USER NICKSCOTT3;

CREATE ROLE kafka_connector_role_1;
GRANT USAGE ON DATABASE kafka_db TO ROLE kafka_connector_role_1;
GRANT USAGE ON SCHEMA kafka_schema TO ROLE kafka_connector_role_1;
GRANT CREATE TABLE ON SCHEMA kafka_schema TO ROLE kafka_connector_role_1;
GRANT CREATE STAGE ON SCHEMA kafka_schema TO ROLE kafka_connector_role_1;
GRANT CREATE PIPE ON SCHEMA kafka_schema TO ROLE kafka_connector_role_1;
GRANT OWNERSHIP ON TABLE existing_table1 TO ROLE kafka_connector_role_1;
GRANT READ, WRITE ON STAGE existing_stage1 TO ROLE kafka_connector_role_1;
GRANT ROLE kafka_connector_role_1 TO USER kafka_connector_user_1;
ALTER USER kafka_connector_user_1 SET DEFAULT_ROLE = kafka_connector_role_1;

CREATE DATABASE BOOKIBET_PROD;
CREATE SCHEMA BOOKIBET_PROD.RAW;
CREATE WAREHOUSE WH_INGEST_PROD
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
CREATE ROLE KAFKA_CONNECT_ROLE_PROD;
GRANT USAGE ON WAREHOUSE WH_INGEST_PROD TO ROLE KAFKA_CONNECT_ROLE_PROD;
GRANT USAGE ON DATABASE BOOKIBET_PROD TO ROLE KAFKA_CONNECT_ROLE_PROD;
GRANT USAGE ON SCHEMA BOOKIBET_PROD.RAW TO ROLE KAFKA_CONNECT_ROLE_PROD;
GRANT CREATE TABLE, INSERT, SELECT ON SCHEMA BOOKIBET_PROD.RAW TO ROLE KAFKA_CONNECT_ROLE_PROD;
GRANT ROLE KAFKA_CONNECT_ROLE_PROD TO USER NICKSCOTT3;

GRANT ROLE ROLE_KAFKA_DEV TO USER KAFKA_CONNECT_DEV;
```

## 2026-01-14 – Snowflake init scripts + execution status

- New init files split by role context:
  - `init_001_securityadmin.sql` (roles/users/RSA keys)
  - `init_002_sysadmin.sql` (DB/schema/warehouse/grants)
- Confirmed updates applied in Snowflake successfully using the split scripts.
- Note: staging DB/schema/warehouse creation required running as `ACCOUNTADMIN` in the Snowflake UI (SYSADMIN failed for schema creation).

## 2026-01-15 – Staging connector + Kafka test path

- Snowflake connector is RUNNING (name: `snowflake-sink`) with `KAFKA_CONNECT_STAGING`, `BOOKIBET_STAGING.RAW`, `WH_INGEST_STAGING`.
- Connector requires `snowflake.private.key` in config; key injected via `SNOWFLAKE_PRIVATE_KEY_P8` env var (file-only did not validate).
- Kafka REST Proxy added to CFK Helm chart and enabled for staging; required for Avro test via REST.
- Avro test script updated to create the topic via REST Admin API before producing (topic auto-create is off).
- Broker crashloop root cause: hard-coded `node.id`/`broker.id` in Kafka CR; removed from `infra/platform/charts/confluent-platform/templates/kafka.yaml`.
- Kubeconfig auth note: avoid `--role-arn` when already on `cli-admin` (self-assume fails).
- End-to-end test succeeded: REST Proxy -> Schema Registry -> Kafka -> Snowflake; table `BOOKIBET_STAGING.RAW.BM_TEST` created and row inserted.
- Remaining: scale brokers back to 3 (staging values) and confirm Kafka/Connect stability post-scale.

## Next Steps (short)

- Scale staging Kafka brokers to 3 and verify `kafka-0/1/2` Ready.
- Re-run Avro test via REST Proxy and confirm Snowflake table inserts post-scale.
- Decide on public ingress (API Gateway/VPC Link) for external clients; single protected route likely enough for now.
- Add ksqlDB to CFK stack (new CR + service + values); do not implement yet.

## Pattern Notes (timeline summary)

- Repeated blockers were env/config drift (roles/keys/warehouse not aligned) and missing infra components (REST Proxy, connector plugin build).
- Kubeconfig self-assume confusion caused repeated auth failures; avoid `--role-arn` when already on `cli-admin`.
- Kafka broker stability issues traced to hard-coded broker IDs; fix now allows safe scale-out.

## 2025-12-24 – GitOps/branching strategy (solo)

- Source of truth: `main` holds workflows and infra templates.
- Staging: branch `staging` for BA testing; staging deploys on push to `staging` or manual run.
- Prod: short-lived `release/*` branches cut from `main`; prod deploys only from `release/*`.
- Flow: feature work -> merge to `main` -> update `staging` -> cut `release/*` when ready -> deploy prod -> merge back to `main` -> delete release branch.

## 2025-12-24 – Current status (staging/prod deploy prep)

- Added push triggers:
  - Staging deploy runs on push to `staging` (and manual).
  - Prod deploy runs on push to `release/*` (and manual).
- Actions UI mismatch: `main` still has combined `deploy-staging-prod.yml`; needs replacing with separate staging/prod workflows on `main` to show correctly in GitHub Actions.
- Local branch status: working on `staging` branch; need to merge `staging` -> `main` and push so workflows update in Actions.

## 2026-01-16 – Current context (Kong OSS + Snowflake grants)

- Docs work (bookibet-docs):
  - Added Kong OSS, DB-less, in-cluster decision and auth constraints (no OIDC in OSS).
  - Added `api_gateway_ADR.md` and updated `architecture_summary.md` with the Kong decision and optional AWS edge path.
  - Updated docs index in `README.md` to include `api_gateway_ADR.md` and `kong_integration_plan.md`.
- Snowflake connector test path:
  - Connector is RUNNING; Snowpipe flush is batchy (see `buffer.flush.time`/`buffer.count.records`) so expect delay after small test payloads.
  - Added `CREATE STAGE` and `CREATE PIPE` grants (and `DELETE`) in `init_002_sysadmin.sql` for dev/staging/prod roles to unblock pipe creation and cleanup.

## 2026-01-27 – Internal LB for Schema Registry/REST (ECS access plan)

- Goal:
  - Enable ECS workloads (e.g., Neuroplastiq) to reach Schema Registry without relying on Kubernetes DNS or Kong routing.
- Changes:
  - Added internal NLB Services to CFK chart:
    - `schemaregistry-internal` (port 8081)
    - `kafka-rest-internal` (port 8082, gated by Kafka REST enablement)
  - Added values blocks:
    - `schemaRegistryLoadBalancer` and `kafkaRestProxyLoadBalancer`
  - Enabled internal LB for dev/staging/prod values.
- Files:
  - `infra/platform/charts/confluent-platform/templates/schemaregistry-internal-lb.yaml`
  - `infra/platform/charts/confluent-platform/templates/kafka-rest-internal-lb.yaml`
  - `infra/platform/charts/confluent-platform/values.yaml`
  - `infra/platform/charts/confluent-platform/values-dev.yaml`
  - `infra/platform/charts/confluent-platform/values-staging.yaml`
  - `infra/platform/charts/confluent-platform/values-prod.yaml`

Next steps:
- Deploy to staging and capture the internal LB DNS:
  - `kubectl -n confluent get svc schemaregistry-internal`
  - `kubectl -n confluent get svc kafka-rest-internal` (if REST Proxy enabled)
- Verify selectors match CFK pod labels; adjust if no endpoints.

## 2026-01-29 – Neuroplastiq staging deploy prep + RDS + API server

- Schema Registry internal NLB is up in staging:
  - `schemaregistry-internal` DNS:
    - `a3495aa4ae2e247b8bce628c3421eaa0-f6abedba736f161a.elb.ap-southeast-2.amazonaws.com`
- ECR repo created via CFN:
  - `bookibet-staging-neuroplastiq`
  - URI: `838869291259.dkr.ecr.ap-southeast-2.amazonaws.com/bookibet-staging-neuroplastiq`
- Added K8s manifests for Neuroplastiq in `services/neuroplastiq/k8s/`:
  - namespace + service + deployment + secret
  - `SCHEMA_REGISTRY_URL` wired to internal NLB
  - `NEURO_REGISTRY_DB_URL` wired to RDS
- Added dedicated RDS CFN stack for Neuro Registry:
  - `infra/cloudformation/neuro-registry-rds.yml`
  - Endpoint: `bookibet-staging-neuro-registry.cn2k04asgnmd.ap-southeast-2.rds.amazonaws.com:5432`
  - DB name: `neuro_registry`
- Updated deploy runbook:
  - `poc-neuroplastiq-data/docs/deploy-neuroplastiq-staging.md`
  - Now includes API server `/health` + `/analyse` flow and current LB/RDS values.
- Added API server in NPF repo and changed Dockerfile to run uvicorn:
  - `poc-neuroplastiq-data/app/server.py` exposes:
    - `GET /health`
    - `POST /analyse` (runs orchestrator once)
  - Dockerfile now runs `uvicorn app.server:app`
  - `make analyse-staging` added (one-shot local run).
- Current image tag used for staging:
  - `staging-12ed931`
- Runtime issue observed:
  - `/analyse` returned 500 because `connectors` was `null` in config.
  - Fixed in `poc-neuroplastiq-data/core/orchestrator.py` to default to empty list/dict.

Next steps:
- Rebuild + push NPF image with the orchestrator fix and update the deployment image tag.
- Apply manifests:
  - `kubectl apply -f services/neuroplastiq/k8s/secret.yaml`
  - `kubectl apply -f services/neuroplastiq/k8s/deployment.yaml`
  - `kubectl apply -f services/neuroplastiq/k8s/service.yaml`
- Verify:
  - `kubectl -n neuroplastiq port-forward svc/neuroplastiq 18000:8000`
  - `curl http://localhost:18000/health`
  - `curl -X POST http://localhost:18000/analyse`

Morning one-liner (replace TAG if needed):
```
cd /home/elliotrock/Development/poc-neuroplastiq-data && TAG=staging-$(git rev-parse --short HEAD) && docker build -t neuroplastiq:$TAG . && aws ecr get-login-password --region ap-southeast-2 | docker login --username AWS --password-stdin 838869291259.dkr.ecr.ap-southeast-2.amazonaws.com && docker tag neuroplastiq:$TAG 838869291259.dkr.ecr.ap-southeast-2.amazonaws.com/bookibet-staging-neuroplastiq:$TAG && docker push 838869291259.dkr.ecr.ap-southeast-2.amazonaws.com/bookibet-staging-neuroplastiq:$TAG && cd /home/elliotrock/Development/bookibet-platform && sed -i "s#bookibet-staging-neuroplastiq:.*#bookibet-staging-neuroplastiq:$TAG#\" services/neuroplastiq/k8s/deployment.yaml && kubectl apply -f services/neuroplastiq/k8s/deployment.yaml && kubectl -n neuroplastiq rollout status deploy/neuroplastiq
```

## 2026-01-30 – Neuroplastiq staging deploy fixes (platform repo)

- Fixed `services/neuroplastiq/k8s/deployment.yaml` image line formatting (broken quote was causing YAML parse errors).
- Deployed new Neuroplastiq image tag to staging after ECR login refresh and rollout.
- Verified API health and `/analyse` via port-forward once the new deployment was running.

## 2026-02-02 – Neuroplastiq staging debug + Bedrock + schema registry sink

- Bedrock enabled for NPF in staging (LLM provider set to Bedrock with Mistral 7B).
- Confluent Schema Registry internal NLB reachable; `/subjects` returns 200 from in-cluster curl pod.
- Neuro Registry RDS schema initialized; sink health check passes.
- Added detailed runtime logs for LLM, Neuro Registry inserts, and Schema Registry requests/responses in NPF repo.
- Added configurable Avro name prefix support and set `AVRO_NAME_PREFIX: "bm_"` for betmaker-graphql.

Blocking issue:
- No rows in Neuro Registry because GraphQL stub introspection has zero types.
- Live GraphQL introspection to BOS is blocked by WAF.

Next step:
- Work with Betmakers to allow introspection or supply schema SDL.
  - Endpoint (staging):
    ```
    https://bos.spirit.ext.thebetmakers.com/query
    ```

## 2026-02-03 – Cost optimization + staging downscale (EKS/CFK)

- Dev environment removed:
  - Kong uninstalled and `kong` namespace deleted.
  - `bookibet-dev` EKS cluster deleted; nodegroup deletion required `--disable-nodegroup-eviction`.
- Staging nodegroups resized:
  - Added `ng-small` (t3.small) then replaced with `ng-medium` (t3.medium) due to memory pressure.
  - Plan: keep 2 x `t3.medium` to run CFK stack; delete `ng-small` after stability.

## 2026-02-04 – KRaft recovery (staging) when Kafka stuck on license store

Symptoms:
- `kafka-0` crashlooping with:
  - `Failed to start license store with topic _confluent-command`
  - `TimeoutException: Failed to get offsets by times`
- Broker logs may show `MetadataLoader ... still catching up` and readiness probe failing.
- Schema Registry / Connect crashloop because Kafka never becomes Ready.

Root cause:
- KRaft metadata state wedged/inconsistent (not a missing license). Config + cluster IDs can be correct, but broker still fails to read `_confluent-command`.

Fastest recovery (staging only, destructive):
```
kubectl -n confluent delete pvc data0-kafka-0
kubectl -n confluent delete pvc data0-kafka-controller-0
kubectl -n confluent delete pod kafka-0 kafka-controller-0
```

Then:
- Re-run staging deploy (CI/CD) or let StatefulSets recreate.
- Verify `kafka-0` Ready before Schema Registry / Connect.

## 2026-02-04 – Staging debugging + smoke checks

- Kafka remained not Ready during smoke checks; Schema Registry and Connect crashloop while Kafka is down.
- `smoke-checks.sh` updated to wait only on core pods (`kafka-0`, `kafka-controller-0`, `schemaregistry-0`, `connect-0`) instead of `--all`, and to fail fast if missing. This prevents CI hangs on unrelated pods.
- CI/CD staging deploy uses `infra/platform/environments/staging/values-staging.yaml`; added Kafka config overrides there to enforce single‑broker replication factors and disable cluster linking/balancer for staging.
- Added `context_kong_debugging.txt` to `.gitignore`.

Next steps:
- If Kafka still wedged after config changes, perform full KRaft reset (broker + controller PVC wipe) then redeploy.
- Once Kafka Ready, verify Schema Registry and Connect stabilize, then re-run smoke tests.
- CFK chart updates to support smaller footprints:
  - Added `podTemplate` passthrough in chart templates (Kafka, KRaft controller, Schema Registry, Connect, Kafka REST Proxy).
  - Staging values reduced to 1 replica across Kafka/Connect/SR; replication factors set to 1; storage sizes reduced.
  - Per-component resource requests/limits added; Connect memory bumped to 1Gi.
- Current runtime issues/next fixes:
  - Kafka crashloop due to stale KRaft node ID; required PVC/PV reset.
  - Controller Pending due to memory on single node; resolved by scaling nodegroup to 2 x t3.medium.
  - Connect/SR stabilize once Kafka + controller are healthy.

## 2026-02-05 – Snowflake connector + naming alignment (staging)

- Snowflake connector regex updated to match dot‑namespaced topics:
  - `confluent/config/connectors/snowflake/snowflake-sink.json` now uses `topics.regex: ^betmaker\..*`.
- Kafka Connect plugin lifecycle clarified:
  - `connectors-build-apply` installs connector plugins (via Helm values from S3).
  - `connector-apply` only pushes the connector config (requires Snowflake key).
- Port‑forward confusion resolved:
  - Use `kubectl -n confluent port-forward pod/connect-0 18083:8083` to reach Connect; Adminer on 8083 caused false positives.
- Naming decision (revised):
  - Converged on lowercase, dot‑separated subject/namespace convention: `npf.graphql.betmaker.bet`.
  - Kafka topics will be `betmaker.<object>` for Snowflake‑friendly table names (e.g., `betmaker.bet` → `BETMAKER_BET`).

Next steps:
- Ensure Kafka topic naming aligns with `betmaker.<object>` (producer/connector side).
- Re‑apply Snowflake connector config after plugin install and confirm `snowflake-sink` is RUNNING.
- Test Snowflake connector end‑to‑end tomorrow; no schemas landed yet — likely `topics.regex` mismatch.

## 2026-02-06 – Summary correction (post-review)

- Confluent controller/broker/SR/Connect chain is now fixed; topics are arriving.
- Dev environment has been deleted.
- Next step is a simple validation to display the Avro schema from Confluent Schema Registry.
- Kong has been removed; FastAPI is used for internal REST commands.
- Prior "Next steps" blocks above are now outdated; use the 2026-02-06 entries below.

## 2026-02-06 – Open questions / TODO (explore later)

- Needs investigation later (exploratory item).
- Namespacing needs new documentation and a decision:
  - Neuro registry: `npf.<connector_type>.<domain>.<object>`
  - Confluent Schema Registry: `<domain>.<object>`
  - Snowflake tables: `<domain>_<object>`
- Kong is gone for now; FastAPI is the internal REST surface.


## 2026-02-10 – Connector workflow cleanup

### Summary of changes
- Simplified connector operations in `makefile` into explicit targets:
  - `connector-upload`
  - `connector-apply-cluster`
  - `connector-apply-config`
- Added connector selection support with `CONNECTOR=--all` or `CONNECTOR=<name>` (e.g. `snowflake`).
- Kept backward-compatible aliases for older targets:
  - `connectors-upload` -> `connector-upload`
  - `connector-apply` -> `connector-apply-config`
  - `connector-apply-all` -> `CONNECTOR=--all make connector-apply-config`
  - `connectors-build-apply*` -> `connector-apply-cluster`

### Script updates
- `infra/platform/scripts/publish-connectors-s3.sh`
  - Added optional connector filter argument (`[connector|--all]`).
- `infra/platform/scripts/generate-connectors-values.sh`
  - Added optional connector filter argument (`[connector|--all]`).

### Snowflake key handling
- `connector-apply-config` now auto-loads private key if env vars are missing:
  - first `SNOWFLAKE_PRIVATE_KEY_P8` / `SNOWFLAKE_PRIVATE_KEY`
  - fallback file `SNOWFLAKE_PRIVATE_KEY_FILE` (default `../rsa_key.p8`)

### Operational takeaway
- Config apply can fail with class-not-found until cluster plugin step is completed.
- Correct order for staging:
  1. `make connector-apply-cluster ENVIRONMENT=staging CONNECTOR=snowflake`
  2. verify `/connector-plugins` contains `com.snowflake.kafka.connector.SnowflakeSinkConnector`
  3. `make connector-apply-config ENVIRONMENT=staging CONNECTOR=snowflake`

## 2026-02-17 – Staging Confluent status + RF=1 investigation

### Current status
- Staging Confluent deployment is up and functional; Snowflake sink applied and reported `RUNNING`.
- Neuro connector flow now produces successfully via Kafka REST v2 fallback (latest run reached `ok=200 failed=0` for `betmaker.user` and `/connector` returned `200`).

### What was verified today
- Staging deploy path in CI uses env values file:
  - `.github/workflows/deploy-staging.yml` uses `infra/platform/environments/staging/values-staging.yaml`.
- Staging Kafka defaults in repo are RF3/minISR2:
  - `default.replication.factor=3`
  - `min.insync.replicas=2`
  - `offsets.topic.replication.factor=3`
  - `transaction.state.log.replication.factor=3`
- Live broker file checks also showed RF3/minISR2 present in:
  - `/mnt/config/shared/kafka.properties`
  - `/opt/confluentinc/etc/kafka/kafka.properties`

### Important finding (possible RF=1 source)
- `infra/platform/scripts/push-test-schema-and-payload.sh` still creates topics with hardcoded:
  - `"replication_factor":1`
- This is wired via manual make target `push-test-schema`; not part of smoke checks.
- It is still a risk path if run with `TOPIC=betmaker.user` (or copied logic elsewhere).

### Reset/redeploy notes
- Added/used non-prod reset helper:
  - `make confluent-reset-nonprod`
  - `make confluent-verify-offsets`
- Remaining uncertainty: whether reset PVC selectors always match all CFK PVC labels (needs live cluster label verification when auth/session is available).

### Next-day focus (open)
- Track down "lurky RF=1" deterministically:
  1. Capture topic describe + kafka-rest logs immediately on failure.
  2. Confirm runtime broker defaults via `kafka-configs --entity-default --describe --all` (not only file config).
  3. Verify all Confluent PVC labels/names are covered by reset target.
  4. Remove/parameterize hardcoded RF=1 in `push-test-schema-and-payload.sh` to default RF3 for non-dev safety.

## 2026-02-18 – Incident summary (Schema ID + Snowflake sink + cluster stability)

### What happened
- Snowflake sink initially showed stage upload failures:
  - `Insufficient privileges to operate on table stage 'BETMAKER_USER'`.
- Connector task also repeatedly failed on Avro deserialization:
  - `Schema 7 not found; error code: 40403`.
- After offset skips and restarts, failures returned intermittently.
- During recovery, Confluent stack became unstable due to node health issues:
  - `NodeNotReady` / `node.kubernetes.io/unreachable` taints,
  - repeated pod evictions/terminations,
  - stuck `Terminating` pods,
  - `kafka-2` scheduling/PVC affinity issues.
- Neuro `/connector` runs then showed upstream timeout failures (not Snowflake):
  - Kafka REST v2 produce timeouts (`:8082`),
  - Schema Registry lookup timeouts (`:8081`),
  - resulting in `ok=0 failed=200` and no new Kafka records.

### Current understanding of root causes
- Primary platform issue: unstable Kubernetes nodes caused Confluent service instability (Kafka/Connect/Schema Registry/Kafka REST churn).
- Data-plane issue: sink failures on schema `id=7` were from records referencing missing schema IDs in active SR scope (or stale poison records).
- Snowflake issue was real but separate: table-stage privilege/ownership mismatch on `BETMAKER_USER`.
- No Snowflake ingestion progress when Kafka topic log-end offsets are `0` or Neuro produce fails.

### Actions taken
- Granted/validated Snowflake table-stage capability path (table ownership context) for connector role.
- Updated Snowflake sink config for sane buffering and fresh consumer group:
  - `consumer.override.group.id=connect-snowflake-sink-v2`
  - `buffer.count.records=500`
  - `buffer.flush.time=60`
  - `buffer.size.bytes=5000000`
- Reset/advanced sink offsets when needed to bypass poison backlog.
- Recovered cluster by replacing NotReady worker nodes and force-clearing stuck terminating pods.
- Identified kafka broker scheduling blocker for `kafka-2` (`anti-affinity` + node/pvc placement constraints) and continued recovery.

### Important operational notes
- Topic mismatch observed: `betmaker.user` had `ReplicationFactor=1` with `min.insync.replicas=2`.
  - This can break produce with `acks=all` and cause apparent pipeline stalls.
- After platform rebuild/recovery, topic data may be empty (`LOG-END-OFFSET=0`), so Snowflake won’t change until new records are produced successfully.

### Bookibet-platform config status (confirmed)
- `confluent/config/connectors/snowflake/snowflake-sink.json` currently contains:
  - `consumer.override.group.id: connect-snowflake-sink-v2`
  - `buffer.count.records: 500`
  - `buffer.flush.time: 60`
  - `buffer.size.bytes: 5000000`
- `services/neuroplastiq/k8s/deployment.yaml` currently points to image tag:
  - `staging-b336cfd`
- No additional pending config diffs in this repo besides deployment image tag update.

## 2026-02-19 – Platform fixes summary (Bookibet)

### Confluent/Kafka platform fixes tracked
- Recovered from node instability (`NodeNotReady` / `unreachable` taints) that caused repeated pod evictions and stuck terminations.
- Replaced unhealthy worker node(s) via ASG/EC2 termination flow so scheduling resumed.
- Recovered stateful components back to healthy state (Kafka, Connect, Kafka REST, Schema Registry), then resumed connector operations.

### Kafka topic correctness
- `betmaker.user` was recreated with production-safe replication:
  - `PartitionCount=3`
  - `ReplicationFactor=3`
  - `min.insync.replicas=2`
- This addressed prior single-replica risk that could stall produce paths during broker/node instability.

### Snowflake sink connector fixes
- Applied and validated Snowflake sink config updates including:
  - `consumer.override.group.id=connect-snowflake-sink-v3`
  - Avro converter with Schema Registry URL
  - RecordNameStrategy for value/key subject resolution
  - Buffer tuning: `count=500`, `flush.time=60`, `size.bytes=5000000`
- Confirmed that sink task restart sequencing matters:
  - topic + schema registry healthy first,
  - then task restart and ingestion checks.

### Known failure mode to avoid
- Schema subject mismatch (`betmaker.user-value` vs record-name subjects) can fail deserialization if converter strategy and produced subject strategy diverge.
- Keep producer/sink subject strategy aligned before replaying backlog.

### Current operational handoff
- Canonical replay path now:
  1. Neuro `/analyse` (schema registration)
  2. Neuro `/connector` (produce)
  3. Monitor Connect task and Snowflake row/offset movement
- If no Snowflake movement, verify Kafka offsets first before touching pipes/tables.
