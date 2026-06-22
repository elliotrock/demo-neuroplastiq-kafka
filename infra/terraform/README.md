Terraform is available for Snowflake provisioning.

- Snowflake bootstrap: `infra/terraform/snowflake/README.md`
  - Creates DEV/STAGING/PROD databases, schemas, warehouses, and roles.
  - Optional S3 storage integration for Snowpipe.

Note: EKS remains on eksctl for speed of delivery.
