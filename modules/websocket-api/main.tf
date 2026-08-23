terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    archive = { source = "hashicorp/archive" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # createDraft/joinDraft live on the REST API (modules/rest-api) - this
  # WebSocket API is draft-room-only.
  handler_names = [
    "connect", "disconnect", "default",
    "startDraft", "makePick", "pickTimeout", "getDraftState",
  ]

  # Routes served by API Gateway (excludes pickTimeout, which EventBridge
  # Scheduler invokes directly via IAM role, not through the WebSocket API).
  route_to_handler = {
    "$connect"      = "connect"
    "$disconnect"   = "disconnect"
    "$default"      = "default"
    "startDraft"    = "startDraft"
    "makePick"      = "makePick"
    "getDraftState" = "getDraftState"
  }

  pick_timeout_function_name = "fantasy-draft-pickTimeout-${var.env}"

  # Built from account/region rather than referencing
  # aws_lambda_function.handler["pickTimeout"].arn, because that function's
  # own environment variables need this same ARN - a resource cannot
  # reference its own computed attribute from within itself (that's a
  # dependency cycle Terraform will reject). This sidesteps it since a
  # Lambda ARN is fully deterministic from account + region + function name.
  pick_timeout_arn = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${local.pick_timeout_function_name}"

  common_env = {
    CONNECTIONS_TABLE             = var.connections_table_name
    DRAFTS_TABLE                  = var.drafts_table_name
    PLAYERS_TABLE                 = var.players_table_name
    DRAFT_PICKS_TABLE             = var.draft_picks_table_name
    GOOGLE_CLIENT_ID              = var.google_client_id
    WEBSOCKET_MANAGEMENT_ENDPOINT = "https://${aws_apigatewayv2_api.this.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/${aws_apigatewayv2_stage.this.name}"
    SCHEDULER_ROLE_ARN            = aws_iam_role.scheduler_invoke.arn
    PICK_TIMEOUT_FUNCTION_ARN     = local.pick_timeout_arn
  }
}

resource "aws_apigatewayv2_api" "this" {
  name                       = "fantasy-draft-ws-${var.env}"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.env
  auto_deploy = true
}

# ---- Lambda execution role (shared by all 9 functions) ----
resource "aws_iam_role" "lambda_exec" {
  name = "fantasy-draft-lambda-exec-${var.env}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_app" {
  name = "fantasy-draft-lambda-app-${var.env}"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem",
        ]
        Resource = [
          var.connections_table_arn, "${var.connections_table_arn}/index/*",
          var.drafts_table_arn,
          var.players_table_arn,
          var.draft_picks_table_arn,
        ]
      },
      {
        # makePick/pickTimeout write to the per-draft roster table created at
        # draft-creation time (see modules/rest-api's createDraft handler).
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/megadraft-*-rosters"
      },
      {
        Effect   = "Allow"
        Action   = ["execute-api:ManageConnections"]
        Resource = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
      },
      {
        Effect   = "Allow"
        Action   = ["scheduler:CreateSchedule", "scheduler:DeleteSchedule", "scheduler:GetSchedule"]
        Resource = "arn:aws:scheduler:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:schedule/default/pt-*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.scheduler_invoke.arn
      },
    ]
  })
}

# ---- Role EventBridge Scheduler assumes to invoke pickTimeout ----
resource "aws_iam_role" "scheduler_invoke" {
  name = "fantasy-draft-scheduler-invoke-${var.env}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "invoke-pick-timeout"
  role = aws_iam_role.scheduler_invoke.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = local.pick_timeout_arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "handler" {
  for_each          = toset(local.handler_names)
  name              = "/aws/lambda/fantasy-draft-${each.key}-${var.env}"
  retention_in_days = var.log_retention_days
}

data "archive_file" "handler" {
  for_each    = toset(local.handler_names)
  type        = "zip"
  source_file = "${var.lambda_dist_dir}/${each.key}.mjs"
  output_path = "${path.module}/.build/${each.key}.zip"
}

resource "aws_lambda_function" "handler" {
  for_each = toset(local.handler_names)

  function_name    = each.key == "pickTimeout" ? local.pick_timeout_function_name : "fantasy-draft-${each.key}-${var.env}"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "nodejs24.x"
  handler          = "${each.key}.handler"
  filename         = data.archive_file.handler[each.key].output_path
  source_code_hash = data.archive_file.handler[each.key].output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = local.common_env
  }

  depends_on = [aws_cloudwatch_log_group.handler]
}

resource "aws_lambda_permission" "apigw" {
  for_each      = toset(values(local.route_to_handler))
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.handler[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "handler" {
  for_each                  = local.route_to_handler
  api_id                    = aws_apigatewayv2_api.this.id
  integration_type          = "AWS_PROXY"
  integration_uri           = aws_lambda_function.handler[each.value].invoke_arn
  content_handling_strategy = "CONVERT_TO_TEXT"
  passthrough_behavior      = "WHEN_NO_MATCH"
}

resource "aws_apigatewayv2_route" "route" {
  for_each  = local.route_to_handler
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.handler[each.key].id}"
}
