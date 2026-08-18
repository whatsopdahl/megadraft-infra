env         = "prod"
region      = "us-east-1"
root_domain = "whatsopdahl.com"
subdomain   = "megadraft"

cognito_domain_prefix = "fantasy-draft-prod"

# Do not commit real secrets here - pass via -var or a gitignored
# prod.tfvars.local / TF_VAR_ environment variables instead.
google_client_id     = "REPLACE_ME"
google_client_secret = "REPLACE_ME"
