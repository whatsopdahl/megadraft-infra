# fantasy-draft-infrastructure

Terraform for the Fantasy Draft app: Cognito, DynamoDB, API Gateway WebSocket API, Lambda wiring, EventBridge Scheduler, and frontend hosting (S3 + CloudFront + Route53).

See `envs/dev` and `envs/prod` for per-environment configuration. Dev is designed to be fully destroyable and re-appliable on demand (`terraform destroy` / `terraform apply`).

## Prerequisites

- Terraform >= 1.7
- AWS credentials for the target account (us-east-1)
- An existing Route53 hosted zone for your domain
- A Google Cloud OAuth 2.0 client (for Cognito's Google federation). Create it in Google Cloud Console under "APIs & Services > Credentials" as a Web application. You won't have the exact authorized redirect URI until after the first `terraform apply` creates the Cognito Hosted UI domain (it's `https://<cognito_domain_prefix>.auth.us-east-1.amazoncognito.com/oauth2/idpresponse`) — apply once, add the redirect URI to the Google client, then re-apply if needed.
- `fantasy-draft-lambdas` must be built (`pnpm build`, producing `dist/*.mjs`) **before** the first `terraform apply` — the websocket-api module zips those files directly, so they must exist on disk at plan time.

## Deployment order (dev example — prod is identical, swap `dev` for `prod`)

This repo, `fantasy-draft-lambdas`, and `fantasy-draft-frontend` are meant to be deployed in this order, since each step's output feeds the next:

1. **Build the Lambdas first** (Terraform packages these files, so they must exist before `apply`):
   ```sh
   cd ../fantasy-draft-lambdas
   pnpm install
   pnpm build
   ```

2. **One-time: create the Terraform state backend** (S3 bucket + DynamoDB lock table). Only needs to be done once per AWS account, not per environment:
   ```sh
   cd bootstrap
   cp terraform.tfvars.example terraform.tfvars   # fill in a globally-unique state_bucket_name
   terraform init
   terraform apply
   ```
   Copy the `state_bucket_name` output into `envs/dev/backend.tf` and `envs/prod/backend.tf` (replacing `REPLACE_WITH_STATE_BUCKET_NAME`).

3. **Fill in `envs/dev/dev.tfvars`**: your real `root_domain`, and `google_client_id`/`google_client_secret` (or leave those as `REPLACE_ME` and pass real values via `-var` / `TF_VAR_google_client_id` so secrets never touch the tfvars file / git history).

4. **Apply the dev environment**:
   ```sh
   cd envs/dev
   terraform init
   terraform apply -var-file=dev.tfvars
   ```
   This creates the DynamoDB tables, Cognito User Pool (+ Google IdP), the WebSocket API and all 9 Lambdas, and the S3/CloudFront/Route53 frontend hosting shell (CloudFront will just serve nothing useful yet — that's expected until step 6).

5. **Register the Cognito redirect URI with Google**: take the `cognito_hosted_ui_domain` output and add `https://<that domain>/oauth2/idpresponse` as an authorized redirect URI on the Google OAuth client, if you hadn't already.

6. **Configure and build the frontend**, then upload it:
   ```sh
   cd ../../fantasy-draft-frontend
   cp .env.example .env.local
   # Fill in .env.local using this repo's terraform outputs:
   #   VITE_COGNITO_HOSTED_UI_DOMAIN = cognito_hosted_ui_domain
   #   VITE_COGNITO_CLIENT_ID        = cognito_user_pool_client_id
   #   VITE_REDIRECT_URI             = https://<subdomain>.<root_domain>/auth/callback
   #   VITE_WEBSOCKET_URL            = websocket_endpoint
   pnpm install
   pnpm build
   aws s3 sync dist/ s3://<frontend_bucket_name> --delete
   aws cloudfront create-invalidation --distribution-id <frontend_cloudfront_distribution_id> --paths "/*"
   ```
   (`terraform output` in `envs/dev` prints all the values referenced above.)

7. **Seed the player pool** (one-time per sport league, from `fantasy-draft-lambdas`):
   ```sh
   cd ../fantasy-draft-lambdas
   PLAYERS_TABLE=<players_table_name> pnpm seed:players -- --league NBA --file ./data/example-players.json
   ```
   Swap in your own full player list per league — `data/example-players.json` is just a 5-player fixture.

Destroy dev when not in use:

```sh
cd envs/dev
terraform destroy -var-file=dev.tfvars
```
(The state backend from step 2 is intentionally *not* torn down by this — it's shared across dev/prod and has `prevent_destroy` set.)
