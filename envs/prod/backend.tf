terraform {
  backend "s3" {
    bucket       = "fantasy-draft-terraform-state-381491860914"
    key          = "fantasy-draft/prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
