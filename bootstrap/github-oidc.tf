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
