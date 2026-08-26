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

# GitHub's immutable subject-claim format ties the sub claim to these
# permanent numeric IDs instead of the mutable owner/repo names, so a
# recycled or renamed org/repo can never mint a token matching this trust
# policy. IDs don't change even if the repo is renamed - unlike the name
# variables above, these aren't meant to be edited casually.
variable "github_owner_id" {
  description = "Immutable numeric ID of the whatsopdahl GitHub account"
  type        = string
  default     = "10856113"
}

variable "github_lambda_repo_id" {
  description = "Immutable numeric ID of the megadraft-lambdas repo"
  type        = string
  default     = "1338863906"
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
        #
        # Immutable subject format (megadraft-lambdas was created after
        # GitHub's July 2026 cutover): owner and repo names are pinned to
        # their permanent numeric IDs via the "@" separator, so this trust
        # policy can't be hijacked by someone recreating a repo/org with the
        # same name later.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}@${var.github_owner_id}/${var.github_lambda_repo}@${var.github_lambda_repo_id}:environment:*"
        }
      }
    }]
  })
}

# This repo now owns the rest-api/websocket-api Terraform (moved out of
# megadraft-infra to remove the cross-repo build race between the two repos'
# CI). That means the deploy role below needs real create/update/delete on
# Lambda functions, their IAM roles, their log groups, and API Gateway v2 -
# the "code-only, fails closed" scoping this role used to have doesn't apply
# to those resource types anymore. It's still deliberately narrower than
# megadraft-infra's terraform-apply role: no dynamodb table schema, route53,
# acm, cloudfront, or frontend S3 bucket access - those stay exclusively
# managed by megadraft-infra. Reuses local.lambda_fn_arn/iam_role_arn/
# log_group_arn already defined in github-oidc-terraform.tf (same module).

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
        # broad read access. Mutating access for dynamodb/acm/cloudfront/
        # route53/frontend-s3 stays out of this role entirely - those
        # resource types are still exclusively megadraft-infra's.
        Sid    = "TerraformRefreshReadOnly"
        Effect = "Allow"
        Action = [
          "dynamodb:Describe*", "dynamodb:List*",
          "lambda:Get*", "lambda:List*",
          "logs:Describe*", "logs:List*", "logs:Get*", "logs:ListTagsForResource",
          "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
          "acm:Describe*", "acm:List*",
          "cloudfront:Get*", "cloudfront:List*",
          "route53:Get*", "route53:List*",
        ]
        Resource = "*"
      },
      {
        # Separate from the read-only block above because these s3:Get*/
        # s3:List* actions *can* be resource-scoped (unlike the account-wide
        # services up there), so they're pinned to just the two buckets this
        # project owns - the terraform state bucket and the frontend-hosting
        # bucket(s) (fantasy-draft-frontend-<env>-<account_id>) - instead of
        # every bucket in the account.
        #
        # Not just "GetBucket*": the frontend bucket's config reads
        # (accelerate, encryption, lifecycle, replication, ...) use IAM
        # action names that drop "Bucket" entirely, e.g.
        # s3:GetAccelerateConfiguration - so this needs the full s3:Get*/
        # s3:List* surface, not a narrower guess at the exact action list.
        Sid    = "S3ReadOnlyProjectBuckets"
        Effect = "Allow"
        Action = ["s3:Get*", "s3:List*"]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
          "arn:aws:s3:::fantasy-draft-frontend-*-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::fantasy-draft-frontend-*-${data.aws_caller_identity.current.account_id}/*",
        ]
      },
      {
        Sid    = "LambdaManageFunctions"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:DeleteFunction",
          "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion",
          "lambda:TagResource", "lambda:UntagResource",
          "lambda:AddPermission", "lambda:RemovePermission",
          "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
        ]
        Resource = local.lambda_fn_arn
      },
      {
        # Covers both the rest-api/websocket-api Lambda exec roles and the
        # EventBridge Scheduler invoke role (all named fantasy-draft-*).
        # Includes iam:PassRole, scoped to the same prefix, so Terraform can
        # attach these roles to the Lambda functions/schedules it creates.
        Sid    = "IAMManageProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:UntagRole",
          "iam:PassRole",
        ]
        Resource = local.iam_role_arn
      },
      {
        Sid    = "LogsManageLambdaLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
        ]
        Resource = [local.log_group_arn, "${local.log_group_arn}:*"]
      },
      {
        # API Gateway v2 doesn't support resource-scoped IAM for most
        # actions (CreateApi etc. require Resource "*"), so this is scoped
        # by the "/apis" resource namespace instead - full manage of HTTP
        # and WebSocket APIs, nothing else in the account uses API Gateway.
        # CreateApi with tags also POSTs to the separate "/tags" namespace
        # (a distinct ARN resource, not a sub-path of "/apis"), so both are
        # needed.
        Sid      = "ApiGatewayManage"
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = ["arn:aws:apigateway:*::/apis*", "arn:aws:apigateway:*::/tags/*"]
      },
      {
        # modules/player-sync creates the secret container only - no
        # GetSecretValue/PutSecretValue, since Terraform never manages the
        # actual espn_s2/SWID value (set manually, see that repo's README).
        # GetResourcePolicy is a read the provider makes on every
        # create/refresh of aws_secretsmanager_secret (checks for a
        # resource-based policy), not just an update-path action.
        Sid    = "SecretsManagerManageEspnCredentials"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
          "secretsmanager:GetResourcePolicy", "secretsmanager:TagResource", "secretsmanager:UntagResource",
        ]
        Resource = local.espn_credentials_secret_arn
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

# --- terraform-plan (read-only, PR review) ---------------------------------
# Now that this repo owns real Terraform (rest-api/websocket-api), PRs
# against it get the same plan-preview treatment megadraft-infra's PRs
# already get, via the same pattern: a read-only role trusted only for the
# pull_request subject.

resource "aws_iam_role" "github_actions_lambda_terraform_plan" {
  name = "github-actions-lambda-terraform-plan"

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
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}@${var.github_owner_id}/${var.github_lambda_repo}@${var.github_lambda_repo_id}:pull_request"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_lambda_terraform_plan" {
  name = "lambda-terraform-plan"
  role = aws_iam_role.github_actions_lambda_terraform_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformPlanReadOnly"
        Effect = "Allow"
        Action = [
          "dynamodb:Describe*", "dynamodb:List*",
          "lambda:Get*", "lambda:List*",
          "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
          "logs:Describe*", "logs:List*", "logs:Get*", "logs:ListTagsForResource",
          "apigateway:GET",
        ]
        Resource = "*"
      },
      {
        Sid      = "SecretsManagerReadOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"]
        Resource = local.espn_credentials_secret_arn
      },
      {
        Sid    = "S3ReadOnlyProjectBuckets"
        Effect = "Allow"
        Action = ["s3:Get*", "s3:List*"]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
        ]
      },
      {
        # S3 native state locking (use_lockfile) takes a conditional
        # PutObject/DeleteObject against a .tflock object even for a
        # read-only `terraform plan`, so this needs write access to the
        # lock file despite otherwise being read-only.
        Sid      = "TerraformStateLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.terraform_state.arn}/fantasy-draft/*"
      },
    ]
  })
}

output "github_actions_lambda_terraform_plan_role_arn" {
  value = aws_iam_role.github_actions_lambda_terraform_plan.arn
}
