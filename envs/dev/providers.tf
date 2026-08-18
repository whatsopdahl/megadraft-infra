terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "fantasy-draft"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront requires its ACM certificate in us-east-1 regardless of the
# primary region, so the frontend-hosting module's cert is created via this
# aliased provider.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "fantasy-draft"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}
