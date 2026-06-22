output "databases" {
  value = { for k, v in snowflake_database.bookibet : k => v.name }
}

output "warehouses" {
  value = { for k, v in snowflake_warehouse.bookibet : k => v.name }
}

output "roles" {
  value = { for k, v in snowflake_role.kafka : k => v.name }
}

output "storage_integration_name" {
  value       = var.enable_storage_integration ? snowflake_storage_integration.s3_snowpipe[0].name : null
  description = "Name of the S3 storage integration (when enabled)."
}
