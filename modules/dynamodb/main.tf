# 4 on-demand DynamoDB tables. On-demand (PAY_PER_REQUEST) billing is used
# throughout since traffic is spiky (draft nights) and near-zero otherwise -
# provisioned capacity would waste money sitting idle.

resource "aws_dynamodb_table" "connections" {
  name         = "fantasy-draft-connections-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }

  attribute {
    name = "draftId"
    type = "S"
  }

  # $disconnect only gives us connectionId, so that stays the base table key.
  # Broadcasting a pick/state update to every socket in a draft is the
  # highest-frequency read against this table, so it gets a GSI rather than a
  # Scan+filter (unlike Players/DraftPicks, where partitions are small enough
  # that Query+filter is cheaper than maintaining a GSI).
  global_secondary_index {
    name            = "byDraftId"
    hash_key        = "draftId"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

resource "aws_dynamodb_table" "drafts" {
  name         = "fantasy-draft-drafts-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "draftId"

  attribute {
    name = "draftId"
    type = "S"
  }
}

# Master player reference pool, partitioned by sport league (NBA/NFL/MLB).
# Shared across all drafts - seeded once via the player seed script, not
# duplicated per draft or per league instance.
resource "aws_dynamodb_table" "players" {
  name         = "fantasy-draft-players-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sportLeague"
  range_key    = "playerId"

  attribute {
    name = "sportLeague"
    type = "S"
  }

  attribute {
    name = "playerId"
    type = "S"
  }
}

# Per-draft pick state: who picked whom, in what order.
resource "aws_dynamodb_table" "draft_picks" {
  name         = "fantasy-draft-draft-picks-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "draftId"
  range_key    = "pickNumber"

  attribute {
    name = "draftId"
    type = "S"
  }

  attribute {
    name = "pickNumber"
    type = "N"
  }
}
