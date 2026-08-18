variable "env" {
  type = string
}

variable "lambda_dist_dir" {
  description = "Path to the fantasy-draft-lambdas dist/ directory containing built .mjs handlers"
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "connections_table_name" { type = string }
variable "connections_table_arn"  { type = string }
variable "drafts_table_name"      { type = string }
variable "drafts_table_arn"       { type = string }
variable "players_table_name"     { type = string }
variable "players_table_arn"      { type = string }
variable "draft_picks_table_name" { type = string }
variable "draft_picks_table_arn"  { type = string }

variable "cognito_user_pool_id"        { type = string }
variable "cognito_user_pool_client_id" { type = string }
