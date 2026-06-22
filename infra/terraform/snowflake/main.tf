locals {
  envs = {
    dev = {
      db   = "BOOKIBET_DEV"
      wh   = "WH_DEV"
      role = "ROLE_KAFKA_DEV"
    }
    staging = {
      db   = "BOOKIBET_STG"
      wh   = "WH_STG"
      role = "ROLE_KAFKA_STG"
    }
    prod = {
      db   = "BOOKIBET_PROD"
      wh   = "WH_PROD"
      role = "ROLE_KAFKA_PROD"
    }
  }

  schemas = ["RAW", "CORE", "MARTS"]

  schema_matrix = {
    for env_key, env in local.envs :
    for schema_name in local.schemas :
    "${env_key}_${schema_name}" => {
      env_key = env_key
      name    = schema_name
    }
  }
}

resource "snowflake_database" "bookibet" {
  for_each = local.envs

  name    = each.value.db
  comment = "Bookibet ${upper(each.key)} database."
}

resource "snowflake_schema" "bookibet" {
  for_each = local.schema_matrix

  database = snowflake_database.bookibet[each.value.env_key].name
  name     = each.value.name
  comment  = "${each.value.name} schema."
}

resource "snowflake_warehouse" "bookibet" {
  for_each = local.envs

  name           = each.value.wh
  warehouse_size = var.warehouse_size
  auto_suspend   = var.warehouse_auto_suspend_seconds
  auto_resume    = true
  initially_suspended = true
  comment        = "Bookibet ${upper(each.key)} warehouse."
}

resource "snowflake_role" "kafka" {
  for_each = local.envs

  name    = each.value.role
  comment = "Kafka ingestion role for ${upper(each.key)}."
}

resource "snowflake_database_grant" "db_usage" {
  for_each = local.envs

  database_name = snowflake_database.bookibet[each.key].name
  privilege     = "USAGE"
  roles         = [snowflake_role.kafka[each.key].name]
}

resource "snowflake_schema_grant" "schema_usage" {
  for_each = local.schema_matrix

  database_name = snowflake_database.bookibet[each.value.env_key].name
  schema_name   = each.value.name
  privilege     = "USAGE"
  roles         = [snowflake_role.kafka[each.value.env_key].name]
}

resource "snowflake_warehouse_grant" "warehouse_usage" {
  for_each = local.envs

  warehouse_name = snowflake_warehouse.bookibet[each.key].name
  privilege      = "USAGE"
  roles          = [snowflake_role.kafka[each.key].name]
}
