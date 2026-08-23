locals {
  cors_allow_origins = ["https://${var.subdomain}.${var.root_domain}"]
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  env = var.env
}

module "websocket_api" {
  source = "../../modules/websocket-api"

  env                = var.env
  lambda_dist_dir    = var.lambda_dist_dir
  log_retention_days = var.log_retention_days

  connections_table_name = module.dynamodb.connections_table_name
  connections_table_arn  = module.dynamodb.connections_table_arn
  drafts_table_name      = module.dynamodb.drafts_table_name
  drafts_table_arn       = module.dynamodb.drafts_table_arn
  players_table_name     = module.dynamodb.players_table_name
  players_table_arn      = module.dynamodb.players_table_arn
  draft_picks_table_name = module.dynamodb.draft_picks_table_name
  draft_picks_table_arn  = module.dynamodb.draft_picks_table_arn

  google_client_id = var.google_client_id
}

module "rest_api" {
  source = "../../modules/rest-api"

  env                = var.env
  lambda_dist_dir    = var.lambda_dist_dir
  log_retention_days = var.log_retention_days

  drafts_table_name      = module.dynamodb.drafts_table_name
  drafts_table_arn       = module.dynamodb.drafts_table_arn
  connections_table_name = module.dynamodb.connections_table_name
  connections_table_arn  = module.dynamodb.connections_table_arn

  google_client_id   = var.google_client_id
  cors_allow_origins = local.cors_allow_origins

  websocket_execution_arn       = module.websocket_api.execution_arn
  websocket_management_endpoint = module.websocket_api.management_endpoint
}

module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  env         = var.env
  root_domain = var.root_domain
  subdomain   = var.subdomain
}
