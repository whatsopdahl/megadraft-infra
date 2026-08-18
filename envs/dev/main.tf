locals {
  full_domain = "${var.subdomain}.${var.root_domain}"

  # Cognito Hosted UI needs the frontend's callback/logout URLs. Using the
  # planned CloudFront domain here; update if you serve auth callbacks from a
  # different path.
  callback_urls = ["https://${local.full_domain}/auth/callback", "http://localhost:5173/auth/callback"]
  logout_urls   = ["https://${local.full_domain}/", "http://localhost:5173/auth/callback"]
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  env = var.env
}

module "cognito" {
  source = "../../modules/cognito"

  env                   = var.env
  callback_urls         = local.callback_urls
  logout_urls           = local.logout_urls
  google_client_id      = var.google_client_id
  google_client_secret  = var.google_client_secret
  cognito_domain_prefix = var.cognito_domain_prefix
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

  cognito_user_pool_id        = module.cognito.user_pool_id
  cognito_user_pool_client_id = module.cognito.user_pool_client_id
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
