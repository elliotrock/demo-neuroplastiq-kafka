SHELL := /bin/bash
.ONESHELL:

# kubectl -n confluent exec kafka-0 -c kafka -- \
  kafka-configs --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --entity-type topics --entity-name betmaker.user \
  --alter --add-config min.insync.replicas=1

  # patch if the lurky RF=1 pops up


# bookibet-dev-connectors-838869291259-ap-southeast-2

# examples;
# eval "$(make auth)"
# Port forwarding:
# kubectl -n neuroplastiq port-forward svc/neuroplastiq 18000:8000

# Neuroplastiq note:
# - Sharded graphql worker tests are driven from the poc-neuroplastiq-data repo Makefile.
# - Racing raw discovery objects like `meetingsBetween` are separate from the BOS seed/fan-out objects.
# - For sharded runs, inspect worker/job logs rather than only deploy/neuroplastiq logs.

.PHONY: auth
auth:
	@read -p "Key ID: " key_id; \
	read -s -p "Secret: " secret; echo; \
	export AWS_ACCESS_KEY_ID="$$key_id"; \
	export AWS_SECRET_ACCESS_KEY="$$secret"; \
	export AWS_REGION=ap-southeast-2; \
	unset AWS_SESSION_TOKEN; \
	CREDS=$$(aws sts assume-role --role-arn arn:aws:iam::838869291259:role/cli-admin --role-session-name local-cli); \
	AWS_ACCESS_KEY_ID=$$(echo "$$CREDS" | jq -r .Credentials.AccessKeyId); \
	AWS_SECRET_ACCESS_KEY=$$(echo "$$CREDS" | jq -r .Credentials.SecretAccessKey); \
	AWS_SESSION_TOKEN=$$(echo "$$CREDS" | jq -r .Credentials.SessionToken); \
	printf 'export AWS_ACCESS_KEY_ID=%s\nexport AWS_SECRET_ACCESS_KEY=%s\nexport AWS_SESSION_TOKEN=%s\nexport AWS_REGION=ap-southeast-2\n' \
		"$$AWS_ACCESS_KEY_ID" "$$AWS_SECRET_ACCESS_KEY" "$$AWS_SESSION_TOKEN"

# Grants the cli-admin role cluster admin via EKS Access Entries for the target cluster.
# Example (staging): EKS_CLUSTER_NAME=bookibet-staging EKS_ROLE_ARN=arn:aws:iam::838869291259:role/cli-admin make eks-access-admin
.PHONY: eks-access-admin
eks-access-admin:
	@if [[ -z "$$EKS_CLUSTER_NAME" || -z "$$EKS_ROLE_ARN" ]]; then \
		echo "Usage: EKS_CLUSTER_NAME=<cluster> EKS_ROLE_ARN=<role-arn> make eks-access-admin"; \
		exit 1; \
	fi
	aws eks create-access-entry \
		--cluster-name "$$EKS_CLUSTER_NAME" \
		--principal-arn "$$EKS_ROLE_ARN" \
		--type STANDARD
	aws eks associate-access-policy \
		--cluster-name "$$EKS_CLUSTER_NAME" \
		--principal-arn "$$EKS_ROLE_ARN" \
		--policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
		--access-scope type=cluster

# Refresh kubeconfig token for an EKS cluster. Run: eval "$(make auth)" first.
# Example (staging): EKS_CLUSTER_NAME=bookibet-staging EKS_ROLE_ARN=arn:aws:iam::838869291259:role/cli-admin AWS_REGION=ap-southeast-2 make kubeconfig-refresh
# or eval "$(make auth)"
# aws eks update-kubeconfig --region ap-southeast-2 --name bookibet-staging

# aws eks update-kubeconfig --region ap-southeast-2 --name bookibet-dev

.PHONY: kubeconfig-refresh
kubeconfig-refresh:
	@if [[ -z "$$EKS_CLUSTER_NAME" ]]; then \
		echo "Usage: EKS_CLUSTER_NAME=<cluster> EKS_ROLE_ARN=<role-arn> AWS_REGION=<region> make kubeconfig-refresh"; \
		exit 1; \
	fi
	@role_arg=(); \
	if [[ -n "$$EKS_ROLE_ARN" ]]; then role_arg=(--role-arn "$$EKS_ROLE_ARN"); fi; \
	aws eks update-kubeconfig --region "$${AWS_REGION:-ap-southeast-2}" --name "$$EKS_CLUSTER_NAME" "$${role_arg[@]}"

# Refresh kubeconfig without assuming a role (use when already authenticated as target IAM user).
# Example (staging): EKS_CLUSTER_NAME=bookibet-staging AWS_REGION=ap-southeast-2 make kubeconfig-refresh-no-role
.PHONY: kubeconfig-refresh-no-role
kubeconfig-refresh-no-role:
	@if [[ -z "$$EKS_CLUSTER_NAME" ]]; then \
		echo "Usage: EKS_CLUSTER_NAME=<cluster> AWS_REGION=<region> make kubeconfig-refresh-no-role"; \
		exit 1; \
	fi
	aws eks update-kubeconfig --region "$${AWS_REGION:-ap-southeast-2}" --name "$$EKS_CLUSTER_NAME"

# Note: These are legacy as I moved the connector upload and config in the CI/CD process.

.PHONY: connector-upload connector-apply-config connector-status connectors-upload connector-apply connector-apply-all
# Upload connector plugin ZIPs to S3.
# - All connectors: make connector-upload ENVIRONMENT=staging CONNECTOR=--all
# - One connector:  make connector-upload ENVIRONMENT=staging CONNECTOR=snowflake
# Optional vars:
# - CONNECTOR_BUCKET (default: bookibet-<env>-connectors-<account>-<region>)
# - AWS_REGION (default: ap-southeast-2)
# - AWS_ACCOUNT_ID (default: 838869291259)
# - CONNECTOR_S3_PREFIX (default: connectors)
connector-upload:
	@ENVIRONMENT="$${ENVIRONMENT:-staging}"; \
	AWS_REGION="$${AWS_REGION:-ap-southeast-2}"; \
	AWS_ACCOUNT_ID="$${AWS_ACCOUNT_ID:-838869291259}"; \
	CONNECTOR="$${CONNECTOR:---all}"; \
	CONNECTOR_BUCKET="$${CONNECTOR_BUCKET:-bookibet-$${ENVIRONMENT}-connectors-$${AWS_ACCOUNT_ID}-$${AWS_REGION}}"; \
	S3_PREFIX="$${CONNECTOR_S3_PREFIX:-connectors}"; \
	if [[ "$$ENVIRONMENT" != "staging" ]]; then \
		echo "Warning: only staging is currently in active use for connector flows (ENVIRONMENT=$$ENVIRONMENT)."; \
	fi; \
	if [[ "$$CONNECTOR" == "--all" || "$$CONNECTOR" == "all" ]]; then \
		infra/platform/scripts/publish-connectors-s3.sh "$$CONNECTOR_BUCKET" "$$AWS_REGION" "$$S3_PREFIX"; \
		exit $$?; \
	fi; \
	CONNECTOR_DIR="confluent/connectors/$$CONNECTOR"; \
	if [[ ! -d "$$CONNECTOR_DIR" ]]; then \
		echo "Connector directory not found: $$CONNECTOR_DIR"; \
		exit 1; \
	fi; \
	shopt -s nullglob; \
	artifacts=("$$CONNECTOR_DIR"/*.zip); \
	shopt -u nullglob; \
	if [[ $${#artifacts[@]} -eq 0 ]]; then \
		echo "No ZIP artifacts found in $$CONNECTOR_DIR"; \
		exit 1; \
	fi; \
	for artifact in "$${artifacts[@]}"; do \
		file_name="$$(basename "$$artifact")"; \
		s3_key="$$S3_PREFIX/$$CONNECTOR/$$file_name"; \
		echo "Uploading $$artifact -> s3://$$CONNECTOR_BUCKET/$$s3_key"; \
		aws s3 cp "$$artifact" "s3://$$CONNECTOR_BUCKET/$$s3_key" --region "$$AWS_REGION"; \
	done

# Apply connector config(s) to Kafka Connect.
# CI/CD note: deploy workflows also run apply-and-verify-connectors.sh to apply these configs and enforce RUNNING connector/task status.
# CI/CD mirrors this local flow:
# - wait for Connect readiness,
# - apply JSON config(s),
# - fail deploy if any connector/task is not RUNNING.
# - All connectors: make connector-apply-config ENVIRONMENT=staging CONNECTOR=--all
# - One connector:  make connector-apply-config ENVIRONMENT=staging CONNECTOR=snowflake
# Optional vars:
# - CONNECTOR_CONFIG_ROOT (default: confluent/config/connectors)
# - CONNECTOR_CONFIG (explicit file path override for single-connector mode)
connector-apply-config:
	@ENVIRONMENT="$${ENVIRONMENT:-staging}"; \
	CONNECTOR="$${CONNECTOR:---all}"; \
	CONFIG_ROOT="$${CONNECTOR_CONFIG_ROOT:-confluent/config/connectors}"; \
	SNOWFLAKE_PRIVATE_KEY_P8_VALUE="$${SNOWFLAKE_PRIVATE_KEY_P8:-$${SNOWFLAKE_PRIVATE_KEY:-}}"; \
	if [[ -z "$$SNOWFLAKE_PRIVATE_KEY_P8_VALUE" ]]; then \
		SNOWFLAKE_PRIVATE_KEY_FILE="$${SNOWFLAKE_PRIVATE_KEY_FILE:-../rsa_key.p8}"; \
		if [[ -f "$$SNOWFLAKE_PRIVATE_KEY_FILE" ]]; then \
			SNOWFLAKE_PRIVATE_KEY_P8_VALUE="$$(tr -d '\r' < "$$SNOWFLAKE_PRIVATE_KEY_FILE")"; \
		fi; \
	fi; \
	if [[ "$$ENVIRONMENT" != "staging" ]]; then \
		echo "Warning: only staging is currently in active use for connector flows (ENVIRONMENT=$$ENVIRONMENT)."; \
	fi; \
	if [[ "$$CONNECTOR" == "--all" || "$$CONNECTOR" == "all" ]]; then \
		CONFIGS_DIR="$$CONFIG_ROOT"; \
		if [[ -d "$$CONFIG_ROOT/$$ENVIRONMENT" ]]; then \
			CONFIGS_DIR="$$CONFIG_ROOT/$$ENVIRONMENT"; \
		fi; \
		SNOWFLAKE_PRIVATE_KEY_P8="$$SNOWFLAKE_PRIVATE_KEY_P8_VALUE" \
		CONNECT_URL="$$CONNECT_URL" CONNECT_NAMESPACE="$$CONNECT_NAMESPACE" CONNECT_SERVICE="$$CONNECT_SERVICE" \
		CONNECT_LOCAL_PORT="$$CONNECT_LOCAL_PORT" CONNECT_KUBE_CONTEXT="$$CONNECT_KUBE_CONTEXT" \
		CONNECTORS_DIR="$$CONFIGS_DIR" infra/platform/scripts/register-connectors.sh; \
		exit $$?; \
	fi; \
	CONNECTOR_CONFIG="$${CONNECTOR_CONFIG:-}"; \
	if [[ -z "$$CONNECTOR_CONFIG" ]]; then \
		CONNECTOR_DIR="$$CONFIG_ROOT/$$CONNECTOR"; \
		if [[ -d "$$CONFIG_ROOT/$$ENVIRONMENT/$$CONNECTOR" ]]; then \
			CONNECTOR_DIR="$$CONFIG_ROOT/$$ENVIRONMENT/$$CONNECTOR"; \
		fi; \
		if [[ ! -d "$$CONNECTOR_DIR" ]]; then \
			echo "Connector config directory not found: $$CONNECTOR_DIR"; \
			exit 1; \
		fi; \
		candidates=(); \
		[[ -f "$$CONNECTOR_DIR/$$CONNECTOR-$$ENVIRONMENT.json" ]] && candidates+=("$$CONNECTOR_DIR/$$CONNECTOR-$$ENVIRONMENT.json"); \
		[[ -f "$$CONNECTOR_DIR/$$ENVIRONMENT.json" ]] && candidates+=("$$CONNECTOR_DIR/$$ENVIRONMENT.json"); \
		shopt -s nullglob; \
		for cfg in "$$CONNECTOR_DIR"/*-"$$ENVIRONMENT".json; do candidates+=("$$cfg"); done; \
		if [[ $${#candidates[@]} -eq 0 ]]; then \
			for cfg in "$$CONNECTOR_DIR"/*.json; do candidates+=("$$cfg"); done; \
		fi; \
		shopt -u nullglob; \
		if [[ $${#candidates[@]} -eq 0 ]]; then \
			echo "No connector config JSON found in $$CONNECTOR_DIR"; \
			exit 1; \
		fi; \
		if [[ $${#candidates[@]} -gt 1 ]]; then \
			echo "Multiple matching configs for connector '$$CONNECTOR' in $$CONNECTOR_DIR"; \
			printf ' - %s\n' "$${candidates[@]}"; \
			echo "Set CONNECTOR_CONFIG=<path> to choose one."; \
			exit 1; \
		fi; \
		CONNECTOR_CONFIG="$${candidates[0]}"; \
	fi; \
	SNOWFLAKE_PRIVATE_KEY_P8="$$SNOWFLAKE_PRIVATE_KEY_P8_VALUE" \
	CONNECT_URL="$$CONNECT_URL" CONNECT_NAMESPACE="$$CONNECT_NAMESPACE" CONNECT_SERVICE="$$CONNECT_SERVICE" \
	CONNECT_LOCAL_PORT="$$CONNECT_LOCAL_PORT" CONNECT_KUBE_CONTEXT="$$CONNECT_KUBE_CONTEXT" \
	CONNECTOR_CONFIG="$$CONNECTOR_CONFIG" infra/platform/scripts/register-connector.sh

# Backward-compatible aliases
connectors-upload: connector-upload
connector-apply: connector-apply-config
connector-apply-all:
	@CONNECTOR=--all $(MAKE) connector-apply-config

# Check that Snowflake connector plugin is loaded and connector task(s) are RUNNING.
# Example: make connector-status
# Optional vars:
# - CONNECTOR_NAME (default: snowflake-sink)
# - CONNECTOR_CLASS (default: com.snowflake.kafka.connector.SnowflakeSinkConnector)
# - CONNECT_URL, CONNECT_NAMESPACE, CONNECT_SERVICE, CONNECT_LOCAL_PORT, CONNECT_KUBE_CONTEXT
connector-status:
	@CONNECTOR_NAME="$${CONNECTOR_NAME:-snowflake-sink}" \
	CONNECTOR_CLASS="$${CONNECTOR_CLASS:-com.snowflake.kafka.connector.SnowflakeSinkConnector}" \
	CONNECT_URL="$$CONNECT_URL" CONNECT_NAMESPACE="$$CONNECT_NAMESPACE" CONNECT_SERVICE="$$CONNECT_SERVICE" \
	CONNECT_LOCAL_PORT="$$CONNECT_LOCAL_PORT" CONNECT_KUBE_CONTEXT="$$CONNECT_KUBE_CONTEXT" \
	infra/platform/scripts/check-snowflake-connector-status.sh

# Apply connector plugin artifact references into the CFK Helm release so Connect can load/recognize them.
# - All connectors: make connector-apply-cluster ENVIRONMENT=staging CONNECTOR=--all
# - One connector:  make connector-apply-cluster ENVIRONMENT=staging CONNECTOR=snowflake
# Optional vars:
# - CONNECTOR_BUCKET (default: bookibet-<env>-connectors-<account>-<region>)
# - AWS_REGION (default: ap-southeast-2)
# - AWS_ACCOUNT_ID (default: 838869291259)
# - CONNECTOR_S3_PREFIX (default: connectors)
# - CONNECT_NAMESPACE (default: confluent)
# - CONNECT_RELEASE_NAME (default: confluent-platform)
# - CONNECT_VALUES_FILE (default: infra/platform/environments/<env>/values-<env>.yaml)
# - CONNECTORS_VALUES_OUT (default: /tmp/connectors-values.yaml)
.PHONY: connector-apply-cluster connectors-build-apply connectors-build-apply-dev connectors-build-apply-prod
connector-apply-cluster:
	@ENVIRONMENT="$${ENVIRONMENT:-staging}"; \
	AWS_REGION="$${AWS_REGION:-ap-southeast-2}"; \
	AWS_ACCOUNT_ID="$${AWS_ACCOUNT_ID:-838869291259}"; \
	CONNECTOR="$${CONNECTOR:---all}"; \
	CONNECTOR_BUCKET="$${CONNECTOR_BUCKET:-bookibet-$${ENVIRONMENT}-connectors-$${AWS_ACCOUNT_ID}-$${AWS_REGION}}"; \
	S3_PREFIX="$${CONNECTOR_S3_PREFIX:-connectors}"; \
	CONNECT_NAMESPACE="$${CONNECT_NAMESPACE:-confluent}"; \
	CONNECT_RELEASE_NAME="$${CONNECT_RELEASE_NAME:-confluent-platform}"; \
	CONNECT_VALUES_FILE="$${CONNECT_VALUES_FILE:-infra/platform/environments/$${ENVIRONMENT}/values-$${ENVIRONMENT}.yaml}"; \
	CONNECTORS_VALUES_OUT="$${CONNECTORS_VALUES_OUT:-/tmp/connectors-values.yaml}"; \
	if [[ ! -f "$$CONNECT_VALUES_FILE" ]]; then \
		echo "Values file not found: $$CONNECT_VALUES_FILE"; \
		exit 1; \
	fi; \
	if [[ "$$ENVIRONMENT" == "staging" ]] && rg -q 'default\.replication\.factor:\s*1' "$$CONNECT_VALUES_FILE"; then \
		echo "Refusing to apply staging with default.replication.factor=1 in $$CONNECT_VALUES_FILE"; \
		echo "Use infra/platform/environments/staging/values-staging.yaml (RF=3/minISR=2) or override CONNECT_VALUES_FILE explicitly."; \
		exit 1; \
	fi; \
	if [[ "$$ENVIRONMENT" != "staging" ]]; then \
		echo "Warning: only staging is currently in active use for connector flows (ENVIRONMENT=$$ENVIRONMENT)."; \
	fi; \
	infra/platform/scripts/publish-connectors-s3.sh "$$CONNECTOR_BUCKET" "$$AWS_REGION" "$$S3_PREFIX" "$$CONNECTOR"; \
	infra/platform/scripts/generate-connectors-values.sh "$$CONNECTOR_BUCKET" "$$AWS_REGION" "$$CONNECTORS_VALUES_OUT" "$$S3_PREFIX" "$$CONNECTOR"; \
	helm upgrade --install "$$CONNECT_RELEASE_NAME" \
		infra/platform/charts/confluent-platform \
		-n "$$CONNECT_NAMESPACE" \
		-f "$$CONNECT_VALUES_FILE" \
		-f "$$CONNECTORS_VALUES_OUT"

# Backward-compatible aliases
connectors-build-apply: connector-apply-cluster

connectors-build-apply-dev:
	@ENVIRONMENT=dev CONNECT_NAMESPACE="$${CONNECT_NAMESPACE:-confluent}" \
	CONNECTOR_BUCKET="$$CONNECTOR_BUCKET" AWS_REGION="$$AWS_REGION" \
	CONNECTOR="$$CONNECTOR" $(MAKE) connector-apply-cluster

connectors-build-apply-prod:
	@ENVIRONMENT=prod CONNECT_NAMESPACE="$${CONNECT_NAMESPACE:-confluent}" \
	CONNECTOR_BUCKET="$$CONNECTOR_BUCKET" AWS_REGION="$$AWS_REGION" \
	CONNECTOR="$$CONNECTOR" $(MAKE) connector-apply-cluster

# Example (staging): KUBE_CONTEXT=arn:aws:eks:ap-southeast-2:838869291259:cluster/bookibet-staging KONG_NAMESPACE=kong make kong-apply
.PHONY: kong-apply
kong-apply:
	@KONG_NAMESPACE="$${KONG_NAMESPACE:-kong}"; \
	KONG_CONFIG="$${KONG_CONFIG:-infra/kong/kong.yaml}"; \
	KONG_VALUES="$${KONG_VALUES:-infra/kong/values-kong.yaml}"; \
	KUBE_CONTEXT="$${KUBE_CONTEXT:-}"; \
	kubectl_args=(); \
	if [[ -n "$$KUBE_CONTEXT" ]]; then kubectl_args+=(--context "$$KUBE_CONTEXT"); fi; \
	kubectl "$${kubectl_args[@]}" create namespace "$$KONG_NAMESPACE" --dry-run=client -o yaml | \
		kubectl "$${kubectl_args[@]}" apply -f -; \
	kubectl "$${kubectl_args[@]}" -n "$$KONG_NAMESPACE" create configmap kong-config \
		--from-file=kong.yaml="$$KONG_CONFIG" --dry-run=client -o yaml | \
		kubectl "$${kubectl_args[@]}" apply -f -; \
	helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true; \
	helm repo update; \
	helm upgrade --install kong kong/kong -n "$$KONG_NAMESPACE" -f "$$KONG_VALUES"

# Example (staging): KUBE_CONTEXT=arn:aws:eks:ap-southeast-2:838869291259:cluster/bookibet-staging KONG_NAMESPACE=kong LOCAL_KONG_PORT=18080 make kong-port-forward
.PHONY: kong-port-forward
kong-port-forward:
	@KONG_NAMESPACE="$${KONG_NAMESPACE:-kong}"; \
	KONG_PROXY_SERVICE="$${KONG_PROXY_SERVICE:-kong-kong-proxy}"; \
	KONG_PROXY_PORT="$${KONG_PROXY_PORT:-80}"; \
	LOCAL_KONG_PORT="$${LOCAL_KONG_PORT:-18080}"; \
	KUBE_CONTEXT="$${KUBE_CONTEXT:-}"; \
	kubectl_args=(); \
	if [[ -n "$$KUBE_CONTEXT" ]]; then kubectl_args+=(--context "$$KUBE_CONTEXT"); fi; \
	kubectl "$${kubectl_args[@]}" -n "$$KONG_NAMESPACE" port-forward \
		"svc/$$KONG_PROXY_SERVICE" "$$LOCAL_KONG_PORT:$$KONG_PROXY_PORT"

# Example (staging + clean topic): RESET_TOPIC=1 KUBE_CONTEXT=arn:aws:eks:ap-southeast-2:838869291259:cluster/bookibet-staging NAMESPACE=confluent TOPIC=bm_test make push-test-schema
.PHONY: push-test-schema
push-test-schema:
	
	@TOPIC="$$TOPIC" NAMESPACE="$$NAMESPACE" KUBE_CONTEXT="$$KUBE_CONTEXT" \
	TOPIC_PARTITIONS="$$TOPIC_PARTITIONS" TOPIC_REPLICATION_FACTOR="$$TOPIC_REPLICATION_FACTOR" \
	ALLOW_LOW_RF="$$ALLOW_LOW_RF" \
	SCHEMA_REGISTRY_SERVICE="$$SCHEMA_REGISTRY_SERVICE" SCHEMA_REGISTRY_PORT="$$SCHEMA_REGISTRY_PORT" \
	LOCAL_SCHEMA_REGISTRY_PORT="$$LOCAL_SCHEMA_REGISTRY_PORT" KAFKA_REST_SERVICE="$$KAFKA_REST_SERVICE" \
	KAFKA_REST_PORT="$$KAFKA_REST_PORT" LOCAL_KAFKA_REST_PORT="$$LOCAL_KAFKA_REST_PORT" \
	RESET_TOPIC="$$RESET_TOPIC" infra/platform/scripts/push-test-schema-and-payload.sh

# Example (staging): KUBE_CONTEXT=arn:aws:eks:ap-southeast-2:838869291259:cluster/bookibet-staging NAMESPACE=neuroplastiq APP_LABEL=app=neuroplastiq make k8s-logs
.PHONY: k8s-logs
k8s-logs:
	@NAMESPACE="$${NAMESPACE:-neuroplastiq}"; \
	APP_LABEL="$${APP_LABEL:-app=neuroplastiq}"; \
	KUBE_CONTEXT="$${KUBE_CONTEXT:-}"; \
	kubectl_args=(); \
	if [[ -n "$$KUBE_CONTEXT" ]]; then kubectl_args+=(--context "$$KUBE_CONTEXT"); fi; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" logs -l "$$APP_LABEL" --tail=200 -f

# Single post-restart health gate:
# - neuroplastiq app health
# - booki-platform app health
# - Kafka/Confluent broker health
# - Snowflake connector plugin + runtime status
# Example:
# KUBE_CONTEXT=<eks-context> make post-restart-health
# Optional overrides:
# NEURO_NAMESPACE, NEURO_SERVICE, NEURO_PORT
# BOOKI_NAMESPACE, BOOKI_SERVICE, BOOKI_PORT
# CONFLUENT_NAMESPACE, HEALTH_PATHS, TIMEOUT_SECONDS
.PHONY: post-restart-health
post-restart-health:
	@KUBE_CONTEXT="$${KUBE_CONTEXT:-}" \
	NEURO_NAMESPACE="$${NEURO_NAMESPACE:-neuroplastiq}" \
	NEURO_SERVICE="$${NEURO_SERVICE:-}" \
	NEURO_PORT="$${NEURO_PORT:-8000}" \
	BOOKI_NAMESPACE="$${BOOKI_NAMESPACE:-default}" \
	BOOKI_SERVICE="$${BOOKI_SERVICE:-}" \
	BOOKI_PORT="$${BOOKI_PORT:-8080}" \
	CONFLUENT_NAMESPACE="$${CONFLUENT_NAMESPACE:-confluent}" \
	HEALTH_PATHS="$${HEALTH_PATHS:-/health /healthz /ready /readyz /v1/health}" \
	TIMEOUT_SECONDS="$${TIMEOUT_SECONDS:-300}" \
	infra/platform/scripts/post-restart-health-check.sh

# Use case:
# - Force a clean non-prod Confluent rebuild when broker/internal topic state is stale
#   (e.g., old RF=1 internal topics, scheduling drift, repeated startup loops).
# - This is destructive: it deletes CFK CRs and PVCs in the namespace.
# Example:
#   CONFIRM=YES NAMESPACE=confluent KUBE_CONTEXT=<eks-context> make confluent-reset-nonprod
# Then redeploy via pipeline/helm, then run:
#   NAMESPACE=confluent KUBE_CONTEXT=<eks-context> make confluent-verify-offsets
.PHONY: confluent-reset-nonprod confluent-verify-offsets
confluent-reset-nonprod:
	@NAMESPACE="$${NAMESPACE:-confluent}"; \
	KUBE_CONTEXT="$${KUBE_CONTEXT:-}"; \
	CONFIRM="$${CONFIRM:-}"; \
	kubectl_args=(); \
	if [[ -n "$$KUBE_CONTEXT" ]]; then kubectl_args+=(--context "$$KUBE_CONTEXT"); fi; \
	if [[ "$$CONFIRM" != "YES" ]]; then \
		echo "Refusing destructive reset. Re-run with CONFIRM=YES."; \
		echo "Example: CONFIRM=YES NAMESPACE=$$NAMESPACE make confluent-reset-nonprod"; \
		exit 1; \
	fi; \
	echo "WARNING: destructive reset in namespace=$$NAMESPACE"; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete connect connect --ignore-not-found; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete schemaregistry schemaregistry --ignore-not-found; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete kafka kafka --ignore-not-found; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete kraftcontroller kafka-controller --ignore-not-found; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete pvc -l app=kafka --ignore-not-found; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete pvc -l app=kafka-controller --ignore-not-found; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" delete pvc -l app=connect --ignore-not-found || true; \
	echo "Confluent reset complete. Redeploy via pipeline/helm."

confluent-verify-offsets:
	@NAMESPACE="$${NAMESPACE:-confluent}"; \
	KUBE_CONTEXT="$${KUBE_CONTEXT:-}"; \
	kubectl_args=(); \
	if [[ -n "$$KUBE_CONTEXT" ]]; then kubectl_args+=(--context "$$KUBE_CONTEXT"); fi; \
	kubectl "$${kubectl_args[@]}" -n "$$NAMESPACE" exec kafka-0 -c kafka -- \
	  kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
	  --describe --topic __consumer_offsets

# 2026-02-09 Summary:
# - Neuro stub flow validated end-to-end to Kafka topic betmaker.Bet.
# - Snowflake connector plugin loaded (SnowflakeSinkConnector 3.4.0).
# - Snowflake sink must run with buffer.flush.time > 10 in this cluster.
# - To avoid hashed Snowflake table suffixes, set:
#   "snowflake.topic2table.map": "betmaker.user:BETMAKER_USER,betmaker.Bet:BETMAKER_BET"
# - After config edits, re-apply connector config with register-connector.sh.

.PHONY: neuro-summary
neuro-summary:
	@echo "Neuro + Bookibet summary (2026-02-09)"; \
	echo "- Kafka topic: betmaker.Bet"; \
	echo "- Snowflake table target: BOOKIBET_STAGING.RAW.BETMAKER_BET"; \
	echo "- Sink test buffers: count=1 flush=11 bytes=1024"; \
	echo "- Apply sink config: ./infra/platform/scripts/register-connector.sh confluent/config/connectors/snowflake/snowflake-sink.json"; \
	echo "- Next steps:"; \
	echo "  1) run /analyse to produce fresh stub records"; \
	echo "  2) verify connector status is RUNNING"; \
	echo "  3) verify Snowflake rows land in BETMAKER_BET"; \
	echo "  4) switch off stubs after Betmakers whitelist is active"; \
	echo "  5) add connector config apply into GitOps/CI deployment flow"
