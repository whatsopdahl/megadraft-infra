variable "env" {
  description = "Environment name (dev/prod), used for resource naming"
  type        = string
}

variable "callback_urls" {
  description = "Allowed OAuth callback URLs for the app client (frontend login redirect)"
  type        = list(string)
}

variable "logout_urls" {
  description = "Allowed OAuth logout URLs for the app client"
  type        = list(string)
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
  description = "Unique prefix for the Cognito Hosted UI domain (e.g. fantasy-draft-dev)"
  type        = string
}
