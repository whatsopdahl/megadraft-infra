variable "env" {
  description = "Environment name"
  type        = string
  default     = "prod"
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
  description = "Google OAuth client ID, used as the audience when verifying Google ID tokens (public value, safe to commit)"
  type        = string
}

variable "lambda_dist_dir" {
  description = "Path to the lambda repo's dist/ directory (run `pnpm build` there first)"
  type        = string
  default     = "../../../lambda/dist"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for each Lambda's log group"
  type        = number
  default     = 14
}
