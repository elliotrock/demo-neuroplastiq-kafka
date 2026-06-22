# Snowflake Kafka Connector (CFK)

This folder is the local source-of-truth for the Snowflake connector plugin bits.

Expected layout:
- Place the downloaded connector ZIP here (for example `snowflake-kafka-connector-1.9.4.zip`).
- Extract the ZIP into `confluent/connectors/snowflake/plugins/` so the JARs live in that folder.

Notes:
- CFK loads plugins via Connect `build` (onDemand) from HTTPS URLs (presigned S3).
- CI publishes artifacts to S3 and generates presigned URLs + checksums during deploy.
- Connect must include `/mnt/plugins` in `plugin.path` to load on-demand installs; the Helm chart sets this.
- Presigned URLs can expire or be invalid if generated with stale AWS creds; rerun `make connectors-build-apply` and restart Connect pods if download returns 400 and `/mnt/plugins` is empty.
- Local helper scripts:
  - `infra/platform/scripts/publish-connectors-s3.sh`
  - `infra/platform/scripts/generate-connectors-values.sh`
- Keep this folder in sync with whatever download method we choose.
