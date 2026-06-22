terraform {
  required_version = ">= 1.5.0"

  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.86"
    }
  }
}

provider "snowflake" {
  account     = var.snowflake_account
  username    = var.snowflake_username
  private_key = var.snowflake_private_key
  role        = var.snowflake_role
}
