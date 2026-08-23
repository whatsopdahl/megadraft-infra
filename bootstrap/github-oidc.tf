# GitHub Actions OIDC: lets the megadraft-lambdas CI workflow assume an AWS
# role via short-lived web-identity credentials (no long-lived access keys
# stored in GitHub). One-time, account-level setup like the rest of
# bootstrap/ - apply this once, then put the role_arn output into the
# megadraft-lambdas repo's AWS_DEPLOY_ROLE_ARN secret.

variable "github_org" {
  description = "GitHub org/user that owns the deploying repo"
  type        = string
  default     = "whatsopdahl"
}

variable "github_lambda_repo" {
  description = "GitHub repo whose Actions workflow is trusted to deploy"
  type        = string
  default     = "megadraft-lambdas"
}

data "aws_caller_identity" "current" {}

# AWS allows only one OIDC provider per issuer URL per account, and this one
# is already owned by another project's Terraform state - it's shared,
# account-wide infrastructure, not something to duplicate or take over here.
# Look it up instead of managing it, so this stack never tries to create or
# destroy it.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-lambda-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # The deploy workflow always runs its job under a GitHub
        # Environment (dev/prod), which changes the token's sub claim to
        # this environment form instead of the usual ref-based one - so
        # only runs executing under a named environment in this repo can
        # assume the role. Pair with required-reviewer protection rules on
        # the "prod" environment (GitHub repo Settings, not Terraform-managed)
        # to gate production deploys behind manual approval.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_lambda_repo}:environment:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "lambda-deploy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # terraform plan/apply refreshes every resource in the stack
        # (dynamodb, apigatewayv2, lambda, iam, logs, acm, cloudfront,
        # route53, s3) even when only Lambda code changed, so it needs
        # broad read access. Mutating access below stays scoped to Lambda
        # + the state bucket, so an apply that would touch anything else
        # in the stack fails closed instead of silently changing it.
        Sid    = "TerraformRefreshReadOnly"
        Effect = "Allow"
        Action = [
          "dynamodb:Describe*", "dynamodb:List*",
          "lambda:Get*", "lambda:List*",
          "apigateway:GET",
          "logs:Describe*", "logs:List*", "logs:Get*", "logs:ListTagsForResource",
          "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
          "acm:Describe*", "acm:List*",
          "cloudfront:Get*", "cloudfront:List*",
          "route53:Get*", "route53:List*",
          "s3:GetBucket*", "s3:ListBucket", "s3:ListAllMyBuckets",
        ]
        Resource = "*"
      },
      {
        Sid    = "DeployLambdaCode"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion",
          "lambda:TagResource",
          "lambda:UntagResource",
        ]
        Resource = "arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:function:fantasy-draft-*"
      },
      {
        Sid      = "TerraformState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.terraform_state.arn}/fantasy-draft/*"
      },
    ]
  })
}

output "github_actions_deploy_role_arn" {
  value = aws_iam_role.github_actions_deploy.arn
}
