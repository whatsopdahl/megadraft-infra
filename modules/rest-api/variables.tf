variable "env" {
  type = string
}

variable "lambda_dist_dir" {
  description = "Path to the lambda repo's dist/ directory containing built .mjs handlers"
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "drafts_table_name" { type = string }
variable "drafts_table_arn" { type = string }
variable "connections_table_name" { type = string }
variable "connections_table_arn" { type = string }

variable "google_client_id" {
  description = "Google OAuth client ID used as the audience when verifying Google ID tokens"
  type        = string
}

variable "cors_allow_origins" {
  description = "Frontend origins allowed to call this API (browser CORS)"
  type        = list(string)
}

variable "websocket_execution_arn" {
  description = "execution_arn of the WebSocket API, so joinDraft/updateDraft can post to connections in a draft room"
  type        = string
}

variable "websocket_management_endpoint" {
  description = "https:// management endpoint of the WebSocket API stage, used to broadcast draftUpdated events"
  type        = string
}
