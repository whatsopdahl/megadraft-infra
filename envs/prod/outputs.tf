output "connections_table_name" {
  value = module.dynamodb.connections_table_name
}

output "drafts_table_name" {
  value = module.dynamodb.drafts_table_name
}

output "players_table_name" {
  value = module.dynamodb.players_table_name
}

output "draft_picks_table_name" {
  value = module.dynamodb.draft_picks_table_name
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_user_pool_client_id" {
  value = module.cognito.user_pool_client_id
}

output "cognito_hosted_ui_domain" {
  value = module.cognito.hosted_ui_domain
}

output "websocket_endpoint" {
  value = module.websocket_api.websocket_endpoint
}

output "frontend_site_url" {
  value = module.frontend_hosting.site_url
}

output "frontend_bucket_name" {
  value = module.frontend_hosting.bucket_name
}

output "frontend_cloudfront_distribution_id" {
  value = module.frontend_hosting.cloudfront_distribution_id
}
