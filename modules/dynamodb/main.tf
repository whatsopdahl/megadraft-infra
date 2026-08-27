# 4 on-demand DynamoDB tables. On-demand (PAY_PER_REQUEST) billing is used
# throughout since traffic is spiky (draft nights) and near-zero otherwise -
# provisioned capacity would waste money sitting idle.
#
# NOTE: table `name` is not updatable in place - changing it forces Terraform
# to destroy and recreate the table (data loss) on the next apply.

resource "aws_dynamodb_table" "connections" {
  name         = "megadraft-connections-${var.env}"
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
  name         = "megadraft-drafts-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "draftId"

  attribute {
    name = "draftId"
    type = "S"
  }

  attribute {
    name = "name"
    type = "S"
  }

  # Lets joinDraft resolve a human-typed draft name to its draftId - joiners
  # don't know the draftId up front, only the name the commissioner shared.
  global_secondary_index {
    name            = "byName"
    hash_key        = "name"
    projection_type = "ALL"
  }
}

# Master player reference pool, partitioned by sport league (NBA/NFL/MLB).
# Shared across all drafts - seeded once via the player seed script, not
# duplicated per draft or per league instance.
resource "aws_dynamodb_table" "players" {
  name         = "megadraft-players-${var.env}"
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
  name         = "megadraft-draft-picks-${var.env}"
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
