variable "env" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "root_domain" {
  description = "Existing Route53-hosted root/apex domain (e.g. example.com)"
  type        = string
}

variable "subdomain" {
  description = "Subdomain to create for this environment (e.g. dev.draft)"
  type        = string
}

variable "google_client_id" {
  description = "Google OAuth 2.0 client ID for Cognito federation"
  type        = string
  sensitive   = true
}

variable "google_client_secret" {
  description = "Google OAuth 2.0 client secret for Cognito federation"
  type        = string
  sensitive   = true
}

variable "cognito_domain_prefix" {
  description = "Unique prefix for the Cognito Hosted UI domain"
  type        = string
}

variable "lambda_dist_dir" {
  description = "Path to the fantasy-draft-lambdas dist/ directory (run `pnpm build` there first)"
  type        = string
  default     = "../../../fantasy-draft-lambdas/dist"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for each Lambda's log group"
  type        = number
  default     = 7
}
