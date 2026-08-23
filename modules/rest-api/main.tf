terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    archive = { source = "hashicorp/archive" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  handler_names = ["createDraft", "getDraft", "updateDraft", "joinDraft"]

  # route_key => handler name
  route_to_handler = {
    "POST /drafts"             = "createDraft"
    "GET /drafts/{draftId}"    = "getDraft"
    "PATCH /drafts/{draftId}"  = "updateDraft"
    "POST /drafts/{draftId}/join" = "joinDraft"
  }

  common_env = {
    DRAFTS_TABLE                  = var.drafts_table_name
    CONNECTIONS_TABLE             = var.connections_table_name
    GOOGLE_CLIENT_ID              = var.google_client_id
    WEBSOCKET_MANAGEMENT_ENDPOINT = var.websocket_management_endpoint
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "fantasy-draft-rest-${var.env}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = ["GET", "POST", "PATCH", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.env
  auto_deploy = true
}

# ---- Lambda execution role (shared by all 4 REST handlers) ----
resource "aws_iam_role" "lambda_exec" {
  name = "fantasy-draft-rest-lambda-exec-${var.env}"
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
  name = "fantasy-draft-rest-lambda-app-${var.env}"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
        ]
        Resource = [var.drafts_table_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = "${var.connections_table_arn}/index/*"
      },
      {
        # createDraft provisions each draft's own roster table on the fly.
        Effect   = "Allow"
        Action   = ["dynamodb:CreateTable"]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/megadraft-*-rosters"
      },
      {
        # joinDraft/updateDraft broadcast draftUpdated into any WS clients
        # already sitting in the draft room.
        Effect   = "Allow"
        Action   = ["execute-api:ManageConnections"]
        Resource = "${var.websocket_execution_arn}/*/*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "handler" {
  for_each = toset(local.handler_names)
  # "rest-" distinguishes these from the WS module's log groups - createDraft
  # and joinDraft used to live there under the bare "fantasy-draft-*" name,
  # and reusing that name here raced the old resource's destroy against this
  # one's create (ResourceAlreadyExistsException) since the two are unrelated
  # resources in different modules with no ordering guarantee between them.
  name              = "/aws/lambda/fantasy-draft-rest-${each.key}-${var.env}"
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

  function_name    = "fantasy-draft-rest-${each.key}-${var.env}"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "nodejs20.x"
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
  for_each               = local.route_to_handler
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.handler[each.value].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "route" {
  for_each  = local.route_to_handler
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.handler[each.key].id}"
}
