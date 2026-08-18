terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

variable "env" {
  type = string
}

variable "root_domain" {
  description = "Existing Route53-hosted root/apex domain, e.g. example.com"
  type        = string
}

variable "subdomain" {
  description = "Subdomain to create for this environment, e.g. dev.draft"
  type        = string
}
