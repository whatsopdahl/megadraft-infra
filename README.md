# fantasy-draft-infrastructure

Terraform for the Fantasy Draft app's shared infrastructure: DynamoDB tables and frontend hosting (S3 + CloudFront + Route53), plus the GitHub Actions OIDC bootstrap for both this repo and [megadraft-lambdas](https://github.com/whatsopdahl/megadraft-lambdas). Authentication is Google Sign-In, verified directly by the Lambdas — there's no Cognito in this stack.

The REST (HTTP) API Gateway for draft setup/editing and the WebSocket API Gateway for the live draft room — along with their Lambda functions, IAM roles, and log groups — live in `megadraft-lambdas`'s own `infrastructure/` directory, not here. They used to live in this repo, built via a cross-repo checkout of `megadraft-lambdas`'s `dist/` output; that broke every time a new handler was added and the two repos' pushes landed out of order. Moving that Terraform into the same repo as the code it deploys removed the race by construction. See that repo's README for the REST/WebSocket API details and its own deployment steps.

See `envs/dev` and `envs/prod` for per-environment configuration. Dev is designed to be fully destroyable and re-appliable on demand (`terraform destroy` / `terraform apply`).

## CI deploys

`bootstrap/github-oidc.tf` provisions the GitHub Actions OIDC provider and IAM roles [megadraft-lambdas](https://github.com/whatsopdahl/megadraft-lambdas)'s workflows assume — `github-actions-lambda-deploy` (full create/update/delete on Lambda functions, their `fantasy-draft-*` IAM roles/log groups, and API Gateway v2 — but never DynamoDB table schema, Route53, ACM, CloudFront, or the frontend S3 bucket, which stay exclusively this repo's) and `github-actions-lambda-terraform-plan` (read-only, for that repo's PR plan checks). Apply `bootstrap` once and put the `github_actions_deploy_role_arn` / `github_actions_lambda_terraform_plan_role_arn` outputs into that repo's secrets — see its README for the full checklist.

This repo's own stack (DynamoDB + frontend hosting) deploys through its own CI: `bootstrap/github-oidc-terraform.tf` provisions two more OIDC roles —

- `.github/workflows/terraform-apply.yml` auto-applies `envs/dev` on every push to `main`, and applies `envs/prod` on a manual `workflow_dispatch` run. It assumes `github-actions-terraform-apply` (full create/update/delete on this repo's stack, trusted only for the `main` branch ref).
- `.github/workflows/terraform-plan.yml` runs `terraform plan` for both envs on every pull request into `main`, so reviewers see the diff before it merges and auto-applies. It assumes `github-actions-terraform-plan` (read-only, trusted for `pull_request` events).

Neither workflow checks out `megadraft-lambdas` anymore — this repo's Terraform has no dependency on that repo's build output at all.

One-time setup, after applying `bootstrap`:

1. Copy the `github_actions_terraform_apply_role_arn` and `github_actions_terraform_plan_role_arn` outputs into this repo's `AWS_TERRAFORM_APPLY_ROLE_ARN` and `AWS_TERRAFORM_PLAN_ROLE_ARN` secrets (Settings → Secrets and variables → Actions).
2. Create a `prod` GitHub Environment (Settings → Environments) with required reviewers, so a `workflow_dispatch` prod apply needs manual approval before it runs.

(No `LAMBDA_REPO_PAT` is needed anymore — safe to remove if you'd set one up.)

## Prerequisites

- Terraform >= 1.7
- AWS credentials for the target account (us-east-1)
- An existing Route53 hosted zone for your domain
- A Google Cloud OAuth 2.0 client (Web application type) for Google Sign-In. Under "Authorized JavaScript origins", add each frontend URL you'll use: `https://<subdomain>.<root_domain>` for the environment, plus `http://localhost:5173` for local dev. No redirect URI and no client secret are needed — the frontend uses Google's client-side ID-token flow. The client ID is also needed by `megadraft-lambdas`'s own Terraform, since that's what runs the REST/WebSocket APIs.

## Deployment order (dev example — prod is identical, swap `dev` for `prod`)

This repo, `../lambda` (including its own `infrastructure/`), and `../frontend` are meant to be deployed in this order, since each step's output feeds the next:

1. **One-time: create the Terraform state backend** (S3 bucket, versioned + encrypted; locking uses S3's native `use_lockfile`, no separate DynamoDB table). Only needs to be done once per AWS account, not per environment:
   ```sh
   cd bootstrap
   cp terraform.tfvars.example terraform.tfvars   # fill in a globally-unique state_bucket_name
   terraform init
   terraform apply
   ```
   Copy the `state_bucket_name` output into `envs/dev/backend.tf` and `envs/prod/backend.tf` (replacing `REPLACE_WITH_STATE_BUCKET_NAME`) — and into `../lambda/infrastructure/envs/{dev,prod}/backend.tf` too, since that stack shares the same state bucket under a different key prefix.

2. **Fill in `envs/dev/dev.tfvars`**: your real `root_domain`.

3. **Apply the dev environment** (DynamoDB tables + the S3/CloudFront/Route53 frontend hosting shell — CloudFront will just serve nothing useful yet, and the REST/WebSocket APIs don't exist yet either, both expected until the next steps):
   ```sh
   cd envs/dev
   terraform init
   terraform apply -var-file=dev.tfvars
   ```

4. **Apply `megadraft-lambdas`'s own `infrastructure/envs/dev`** (builds the Lambdas, creates the REST API, the WebSocket API, and their IAM roles/log groups) — see that repo's README for the exact steps. It needs this repo's DynamoDB tables to already exist (step 3) since its Lambdas read/write them at runtime, though Terraform itself has no direct dependency between the two stacks.

5. **Configure and build the frontend**, then upload it:
   ```sh
   cd ../../frontend
   cp .env.example .env.local
   # Fill in .env.local:
   #   VITE_GOOGLE_CLIENT_ID = the same Google client ID used above
   #   VITE_WEBSOCKET_URL    = websocket_endpoint (from `terraform output` in megadraft-lambdas/infrastructure/envs/dev)
   #   VITE_API_URL          = rest_api_endpoint (from `terraform output` in megadraft-lambdas/infrastructure/envs/dev)
   pnpm install
   pnpm build
   aws s3 sync dist/ s3://<frontend_bucket_name> --delete
   aws cloudfront create-invalidation --distribution-id <frontend_cloudfront_distribution_id> --paths "/*"
   ```
   (`terraform output` in this repo's `envs/dev` prints `frontend_bucket_name` and `frontend_cloudfront_distribution_id`.)

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
