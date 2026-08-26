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
