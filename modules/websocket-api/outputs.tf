output "websocket_endpoint" {
  value = aws_apigatewayv2_stage.this.invoke_url
}

output "management_endpoint" {
  value = local.common_env.WEBSOCKET_MANAGEMENT_ENDPOINT
}

output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "pick_timeout_function_arn" {
  value = local.pick_timeout_arn
}

output "scheduler_role_arn" {
  value = aws_iam_role.scheduler_invoke.arn
}
