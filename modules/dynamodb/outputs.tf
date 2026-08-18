output "connections_table_name" {
  value = aws_dynamodb_table.connections.name
}

output "connections_table_arn" {
  value = aws_dynamodb_table.connections.arn
}

output "drafts_table_name" {
  value = aws_dynamodb_table.drafts.name
}

output "drafts_table_arn" {
  value = aws_dynamodb_table.drafts.arn
}

output "players_table_name" {
  value = aws_dynamodb_table.players.name
}

output "players_table_arn" {
  value = aws_dynamodb_table.players.arn
}

output "draft_picks_table_name" {
  value = aws_dynamodb_table.draft_picks.name
}

output "draft_picks_table_arn" {
  value = aws_dynamodb_table.draft_picks.arn
}
