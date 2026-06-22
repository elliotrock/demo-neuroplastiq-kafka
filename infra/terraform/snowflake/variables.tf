variable "snowflake_account" {
  type        = string
  description = "Snowflake account locator (e.g. xy12345.ap-southeast-2)."
}

variable "snowflake_username" {
  type        = string
  description = "Snowflake user with account admin rights for bootstrap."
}

variable "snowflake_private_key" {
  type        = string
  description = "Snowflake user private key in PEM format."
  sensitive   = true
}

variable "snowflake_role" {
  type        = string
  description = "Role used by Terraform to provision objects."
  default     = "ACCOUNTADMIN"
}

variable "warehouse_size" {
  type        = string
  description = "Default warehouse size for all environments."
  default     = "XSMALL"
}

variable "warehouse_auto_suspend_seconds" {
  type        = number
  description = "Auto suspend in seconds for all warehouses."
  default     = 60
}

variable "enable_storage_integration" {
  type        = bool
  description = "Whether to create an S3 storage integration for Snowpipe."
  default     = false
}

variable "storage_aws_role_arn" {
  type        = string
  description = "IAM role ARN used by Snowflake storage integration."
  default     = ""
}

variable "storage_allowed_locations" {
  type        = list(string)
  description = "Allowed S3 locations for Snowpipe (e.g. [\"s3://bucket/prefix/\"])."
  default     = []
}
