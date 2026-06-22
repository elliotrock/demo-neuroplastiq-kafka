resource "snowflake_storage_integration" "s3_snowpipe" {
  count = var.enable_storage_integration ? 1 : 0

  name                     = "BOOKIBET_S3_INT"
  storage_provider         = "S3"
  enabled                  = true
  storage_aws_role_arn      = var.storage_aws_role_arn
  storage_allowed_locations = var.storage_allowed_locations
  comment                  = "S3 storage integration for Snowpipe."
}
