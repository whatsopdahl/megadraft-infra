# GitHub Actions OIDC: lets the megadraft-frontend repo's CI workflow
# deploy the built frontend (S3 sync + CloudFront invalidation) via
# short-lived web-identity credentials (no long-lived access keys stored in
# GitHub). One-time, account-level setup like the rest of bootstrap/ - apply
# this once, then put the role_arn output into the megadraft-frontend repo's
# AWS_DEPLOY_ROLE_ARN secret.
#
# Deliberately its own role rather than reusing github-actions-terraform-apply
# (megadraft-infra, github-oidc-terraform.tf): that role manages the bucket
# and distribution themselves (create/update/delete), is trusted only for
# megadraft-infra, and has no cloudfront:CreateInvalidation at all. This role
# is the opposite shape - no infrastructure management, just object writes
# and a cache bust - trusted for a different repo entirely.

variable "github_frontend_repo" {
  description = "GitHub repo whose Actions workflow is trusted to deploy the frontend"
  type        = string
  default     = "megadraft-frontend"
}

variable "github_frontend_repo_id" {
  description = "Immutable numeric ID of the megadraft-frontend repo"
  type        = string
  default     = "1338865519"
}

resource "aws_iam_role" "github_actions_frontend_deploy" {
  name = "github-actions-frontend-deploy"

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
        # Same environment-gated shape as the lambda deploy and
        # terraform-apply roles: the deploy workflow's job runs under a
        # GitHub Environment (currently just "dev"), which swaps the
        # token's sub claim to this form instead of the usual ref-based
        # one. Wildcarding the environment name means adding a "prod"
        # environment later (for a prod deploy trigger) needs no further
        # IAM change here - just the new environment + workflow job.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}@${var.github_owner_id}/${var.github_frontend_repo}@${var.github_frontend_repo_id}:environment:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_frontend_deploy" {
  name = "frontend-deploy"
  role = aws_iam_role.github_actions_frontend_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # `aws s3 sync --delete` needs List (to diff against what's already
        # there) and Get (to compare ETags) alongside the writes - not just
        # Put/Delete. Scoped to both env buckets (fantasy-draft-frontend-
        # <env>-<account_id>), same wildcard pattern megadraft-infra's own
        # roles use, so a future prod deploy job needs no IAM change either.
        Sid    = "S3SyncFrontendBuckets"
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::fantasy-draft-frontend-*-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::fantasy-draft-frontend-*-${data.aws_caller_identity.current.account_id}/*",
        ]
      },
      {
        # CloudFront invalidation doesn't support scoping by distribution
        # name/alias (only by the AWS-assigned distribution ID, which isn't
        # known here without a live lookup - see megadraft-infra's own
        # CloudFront management statements, which use Resource "*" for the
        # same reason). Wildcarding just the distribution ID segment keeps
        # this at least account-scoped, tighter than that precedent.
        Sid      = "CloudFrontInvalidateFrontendDistribution"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
      },
    ]
  })
}

output "github_actions_frontend_deploy_role_arn" {
  value = aws_iam_role.github_actions_frontend_deploy.arn
}
