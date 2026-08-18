# Fill in the bucket/table names output by ../../bootstrap after running it
# once. terraform init -backend-config values can also be passed on the CLI
# instead of hardcoding here.
terraform {
  backend "s3" {
    bucket         = "fantasy-draft-terraform-state-381491860914"
    key            = "fantasy-draft/dev/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }
}
