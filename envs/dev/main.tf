module "dynamodb" {
  source = "../../modules/dynamodb"

  env = var.env
}

module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  env         = var.env
  root_domain = var.root_domain
  subdomain   = var.subdomain
}
