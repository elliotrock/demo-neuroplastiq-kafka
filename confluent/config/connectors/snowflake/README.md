# Snowflake connector configuration

This folder holds configuration templates for the Snowflake Kafka Sink connector.

Notes:
- The private key should be mounted into Kafka Connect and referenced by file path.
- Default mount path in this repo: `/etc/secrets/snowflake/rsa_key.p8`.
- Adjust topics, database/schema, warehouse, and role to match each environment.
- The register script accepts either full connector files (`name` + `config`) or a config-only JSON; it will send just the `config` object to the Connect REST API.
- When applying locally, export `SNOWFLAKE_PRIVATE_KEY_P8` (or `SNOWFLAKE_PRIVATE_KEY`) to inject the PEM into `snowflake.private.key` without committing it to git.
