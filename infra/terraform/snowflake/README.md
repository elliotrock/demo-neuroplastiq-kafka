# Snowflake Terraform (Bookibet)

This folder bootstraps Snowflake objects for DEV/STAGING/PROD as per `bookibet-docs/snowflake-integration.md`.

## What this creates

- Databases: `BOOKIBET_DEV`, `BOOKIBET_STG`, `BOOKIBET_PROD`
- Schemas in each database: `RAW`, `CORE`, `MARTS`
- Warehouses: `WH_DEV`, `WH_STG`, `WH_PROD`
- Roles: `ROLE_KAFKA_DEV`, `ROLE_KAFKA_STG`, `ROLE_KAFKA_PROD`
- Optional S3 storage integration for Snowpipe (Snowflake file ingestion)

## Prerequisites (one-time)

1) Create the Snowflake account in the Snowflake web portal.
   - Cloud provider: Amazon Web Services (AWS)
   - Region: ap-southeast-2 (AP-Sydney)
   - Record the account locator (e.g. `xy12345.ap-southeast-2`).

2) Create or choose an admin user for Terraform.
   - Use Snowflake UI: Admin > Users > Create User.
   - Assign `ACCOUNTADMIN` role for bootstrap (you can reduce later).

3) Generate a key pair for the Terraform user.
   - CLI example (OpenSSL):
     - `openssl genrsa -out snowflake_tf_key.pem 2048`
     - `openssl rsa -in snowflake_tf_key.pem -pubout -out snowflake_tf_key.pub`
   - In Snowflake UI: User > Edit > Public Key, paste the contents of `snowflake_tf_key.pub`.

## Configure variables

Create a local tfvars file (do not commit secrets):

```
# terraform.tfvars
snowflake_account             = "<account_locator>"
snowflake_username            = "<terraform_user>"
snowflake_private_key         = "<private_key_pem_contents>"
warehouse_size                = "XSMALL"
warehouse_auto_suspend_seconds = 60

# Enable when you are ready to wire Snowpipe with S3
enable_storage_integration    = false
storage_aws_role_arn          = "arn:aws:iam::<account_id>:role/<role_name>"
storage_allowed_locations     = ["s3://<bucket>/<prefix>/"]
```

## Run

From this folder:

1) `terraform init`
2) `terraform plan`
3) `terraform apply`

## Snowpipe + S3 notes (after enable)

When `enable_storage_integration = true`, Terraform creates the storage integration.
After apply, you must:

1) In Snowflake UI, run:
   - `DESC INTEGRATION BOOKIBET_S3_INT;`
2) Copy:
   - `STORAGE_AWS_IAM_USER_ARN`
   - `STORAGE_AWS_EXTERNAL_ID`
3) In AWS Identity and Access Management (IAM), update the IAM role trust policy to allow the Snowflake IAM user ARN and external ID.
4) Re-run `terraform apply` if you change `storage_allowed_locations`.

## Notes

- This module provisions all DEV/STAGING/PROD objects in a single Snowflake account (as per the architecture decision).
- You can later split to separate Snowflake accounts by duplicating this folder with different credentials.
