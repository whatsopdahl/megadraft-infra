# GitHub Actions OIDC: lets the megadraft-infra repo's own CI workflows
# manage the envs/dev and envs/prod Terraform stacks via short-lived
# web-identity credentials (no long-lived access keys stored in GitHub).
# One-time, account-level setup like the rest of bootstrap/ - apply this
# once, then put the two role ARN outputs into the megadraft-infra repo's
# AWS_TERRAFORM_APPLY_ROLE_ARN and AWS_TERRAFORM_PLAN_ROLE_ARN secrets.
#
# Two roles instead of one:
#   - terraform-apply: full create/update/delete on the fantasy-draft
#     stack. Trusted only for the `ref:refs/heads/main` subject - pushes to
#     main and workflow_dispatch runs started from main. Never assumable
#     from a pull_request event, so a PR branch can never hold write
#     credentials before review.
#   - terraform-plan: read-only. Trusted for the `pull_request` subject so
#     PR workflows can run `terraform plan` for review. GitHub doesn't
#     expose secrets or OIDC tokens to pull_request runs triggered from
#     forks, so trusting this subject broadly is safe.

variable "github_infra_repo" {
  description = "GitHub repo whose Actions workflows manage this Terraform stack"
  type        = string
  default     = "megadraft-infra"
}

variable "github_infra_repo_id" {
  description = "Immutable numeric ID of the megadraft-infra repo"
  type        = string
  default     = "1338859056"
}

# Pinned rather than looked up via a data source, matching how
# github_owner_id/github_lambda_repo_id above are pinned - this stack
# shouldn't need a route53:ListHostedZonesByName permission at bootstrap
# apply time just to resolve an ID that never changes.
variable "route53_root_zone_id" {
  description = "Hosted zone ID for the whatsopdahl.com root domain (envs/*/*.tfvars root_domain)"
  type        = string
  default     = "Z06144703DU9VRG8CMBZW"
}

locals {
  infra_repo_sub_prefix = "repo:${var.github_org}@${var.github_owner_id}/${var.github_infra_repo}@${var.github_infra_repo_id}"

  # ARN patterns for every resource type the fantasy-draft stack's own
  # Terraform manages - shared between the apply role's scoped write
  # statements and the plan role's read-only ones. Deliberately three
  # separate DynamoDB table names (not a "megadraft-*" wildcard): the REST
  # createDraft Lambda also creates one "megadraft-{draftId}-rosters" table
  # per draft at runtime (see README), which Terraform doesn't manage and
  # this CI role should never be able to touch.
  dynamodb_table_arns = [
    "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/megadraft-connections-*",
    "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/megadraft-drafts-*",
    "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/megadraft-players-*",
    "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/megadraft-draft-picks-*",
  ]
  lambda_fn_arn       = "arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:function:fantasy-draft-*"
  iam_role_arn        = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/fantasy-draft-*"
  log_group_arn       = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/fantasy-draft*"
  frontend_bucket_arn = "arn:aws:s3:::fantasy-draft-frontend-*-${data.aws_caller_identity.current.account_id}"
}

# --- terraform-apply -------------------------------------------------------

resource "aws_iam_role" "github_actions_terraform_apply" {
  name = "github-actions-terraform-apply"

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
          "token.actions.githubusercontent.com:sub" = "${local.infra_repo_sub_prefix}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_terraform_apply" {
  name = "terraform-apply"
  role = aws_iam_role.github_actions_terraform_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # terraform plan/apply refreshes every resource in the stack, and
        # these services either don't support resource-level IAM for reads
        # or the resource ID isn't known until after creation, so this
        # stays account-wide read-only. Mutating access for these services
        # is granted separately below, never folded into this statement.
        Sid    = "TerraformRefreshReadOnly"
        Effect = "Allow"
        Action = [
          "acm:Describe*", "acm:List*", "acm:GetCertificate",
          "cloudfront:Get*", "cloudfront:List*",
          "route53:Get*", "route53:List*",
          "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
        ]
        Resource = "*"
      },
      {
        # Table management only - no item-level actions (GetItem/PutItem/
        # Query/Scan/DeleteItem), since Terraform never needs to read or
        # write application data, only schema.
        Sid    = "DynamoDBManageTables"
        Effect = "Allow"
        Action = [
          "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:DescribeTable", "dynamodb:UpdateTable",
          "dynamodb:TagResource", "dynamodb:UntagResource", "dynamodb:ListTagsOfResource",
          "dynamodb:DescribeContinuousBackups", "dynamodb:UpdateContinuousBackups",
          "dynamodb:DescribeTimeToLive", "dynamodb:UpdateTimeToLive",
        ]
        Resource = local.dynamodb_table_arns
      },
      {
        # No lambda:InvokeFunction - Terraform never needs to invoke these,
        # only manage their code/config.
        Sid    = "LambdaManageFunctions"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
          "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion", "lambda:ListVersionsByFunction",
          "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
          "lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy",
          "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
        ]
        Resource = local.lambda_fn_arn
      },
      {
        # Covers both Lambda exec roles and the EventBridge Scheduler
        # invoke role (all named fantasy-draft-*). Includes iam:PassRole,
        # scoped to the same prefix, so Terraform can attach these roles to
        # the Lambda functions and schedules it creates.
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
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
          "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
        ]
        Resource = [local.log_group_arn, "${local.log_group_arn}:*"]
      },
      {
        # API Gateway v2 doesn't support resource-scoped IAM for most
        # actions (CreateApi etc. require Resource "*"), so this is scoped
        # by the "/apis" resource namespace instead - full manage of HTTP
        # APIs, nothing else in the account uses API Gateway.
        Sid      = "ApiGatewayManage"
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = "arn:aws:apigateway:*::/apis*"
      },
      {
        # ACM's RequestCertificate (and most other cert actions) don't
        # support resource-level scoping - the cert ARN doesn't exist until
        # after creation.
        Sid    = "AcmManageCertificates"
        Effect = "Allow"
        Action = [
          "acm:RequestCertificate", "acm:DeleteCertificate",
          "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudFrontManageDistribution"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateDistribution", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
          "cloudfront:CreateOriginAccessControl", "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
          "cloudfront:TagResource", "cloudfront:UntagResource",
        ]
        Resource = "*"
      },
      {
        Sid      = "Route53ManageZoneRecords"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_root_zone_id}"
      },
      {
        Sid      = "S3ManageFrontendBuckets"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = [local.frontend_bucket_arn, "${local.frontend_bucket_arn}/*"]
      },
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/fantasy-draft/*",
        ]
      },
    ]
  })
}

# --- terraform-plan ---------------------------------------------------------

resource "aws_iam_role" "github_actions_terraform_plan" {
  name = "github-actions-terraform-plan"

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
          "token.actions.githubusercontent.com:sub" = "${local.infra_repo_sub_prefix}:pull_request"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_terraform_plan" {
  name = "terraform-plan"
  role = aws_iam_role.github_actions_terraform_plan.id

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
          "acm:Describe*", "acm:List*", "acm:GetCertificate",
          "cloudfront:Get*", "cloudfront:List*",
          "route53:Get*", "route53:List*",
        ]
        Resource = "*"
      },
      {
        Sid    = "S3ReadOnlyProjectBuckets"
        Effect = "Allow"
        Action = ["s3:Get*", "s3:List*"]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
          local.frontend_bucket_arn,
          "${local.frontend_bucket_arn}/*",
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

output "github_actions_terraform_apply_role_arn" {
  value = aws_iam_role.github_actions_terraform_apply.arn
}

output "github_actions_terraform_plan_role_arn" {
  value = aws_iam_role.github_actions_terraform_plan.arn
}
