# fantasy-draft-infrastructure

Terraform for the Fantasy Draft app: DynamoDB, a REST (HTTP) API Gateway for draft setup/editing, a WebSocket API Gateway for the live draft room, Lambda wiring, EventBridge Scheduler, and frontend hosting (S3 + CloudFront + Route53). Authentication is Google Sign-In, verified directly by the Lambdas — there's no Cognito in this stack.

Draft creation (`POST /drafts`), fetching/editing draft settings (`GET`/`PATCH /drafts/{draftId}`), and joining a draft (`POST /drafts/{draftId}/join`) all go through the REST API (`modules/rest-api`). The WebSocket API (`modules/websocket-api`) is reserved for the live draft room: entering/refreshing state (`getDraftState`), starting the draft, and making picks. The REST `createDraft` Lambda also provisions a dedicated per-draft roster table (`megadraft-{draftId}-rosters`, granted via a scoped `dynamodb:CreateTable` IAM permission) that `makePick`/`pickTimeout` write to as picks are made.

See `envs/dev` and `envs/prod` for per-environment configuration. Dev is designed to be fully destroyable and re-appliable on demand (`terraform destroy` / `terraform apply`).

## Prerequisites

- Terraform >= 1.7
- AWS credentials for the target account (us-east-1)
- An existing Route53 hosted zone for your domain
- A Google Cloud OAuth 2.0 client (Web application type) for Google Sign-In. Under "Authorized JavaScript origins", add each frontend URL you'll use: `https://<subdomain>.<root_domain>` for the environment, plus `http://localhost:5173` for local dev. No redirect URI and no client secret are needed — the frontend uses Google's client-side ID-token flow.
- `../lambda` must be built (`pnpm build`, producing `dist/*.mjs`) **before** the first `terraform apply` — the websocket-api module zips those files directly, so they must exist on disk at plan time.

## Deployment order (dev example — prod is identical, swap `dev` for `prod`)

This repo, `../lambda`, and `../frontend` are meant to be deployed in this order, since each step's output feeds the next:

1. **Build the Lambdas first** (Terraform packages these files, so they must exist before `apply`):
   ```sh
   cd ../lambda
   pnpm install
   pnpm build
   ```

2. **One-time: create the Terraform state backend** (S3 bucket, versioned + encrypted; locking uses S3's native `use_lockfile`, no separate DynamoDB table). Only needs to be done once per AWS account, not per environment:
   ```sh
   cd bootstrap
   cp terraform.tfvars.example terraform.tfvars   # fill in a globally-unique state_bucket_name
   terraform init
   terraform apply
   ```
   Copy the `state_bucket_name` output into `envs/dev/backend.tf` and `envs/prod/backend.tf` (replacing `REPLACE_WITH_STATE_BUCKET_NAME`).

3. **Fill in `envs/dev/dev.tfvars`**: your real `root_domain` and `google_client_id` (this is a public value — safe to commit, no secret involved).

4. **Apply the dev environment**:
   ```sh
   cd envs/dev
   terraform init
   terraform apply -var-file=dev.tfvars
   ```
   This creates the DynamoDB tables, the WebSocket API, the REST API, all Lambdas, and the S3/CloudFront/Route53 frontend hosting shell (CloudFront will just serve nothing useful yet — that's expected until step 5).

5. **Configure and build the frontend**, then upload it:
   ```sh
   cd ../../frontend
   cp .env.example .env.local
   # Fill in .env.local:
   #   VITE_GOOGLE_CLIENT_ID = the same Google client ID used above
   #   VITE_WEBSOCKET_URL    = websocket_endpoint (from `terraform output` in envs/dev)
   #   VITE_API_URL          = rest_api_endpoint (from `terraform output` in envs/dev)
   pnpm install
   pnpm build
   aws s3 sync dist/ s3://<frontend_bucket_name> --delete
   aws cloudfront create-invalidation --distribution-id <frontend_cloudfront_distribution_id> --paths "/*"
   ```
   (`terraform output` in `envs/dev` prints `frontend_bucket_name` and `frontend_cloudfront_distribution_id`.)

6. **Seed the player pool** (one-time per sport league, from `../lambda`):
   ```sh
   cd ../lambda
   PLAYERS_TABLE=<players_table_name> pnpm seed:players -- --league NBA --file ./data/example-players.json
   ```
   Swap in your own full player list per league — `data/example-players.json` is just a 5-player fixture.

Destroy dev when not in use:

```sh
cd envs/dev
terraform destroy -var-file=dev.tfvars
```
(The state backend from step 2 is intentionally *not* torn down by this — it's shared across dev/prod and its S3 bucket has `prevent_destroy` set.)
