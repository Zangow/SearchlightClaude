---
name: sl-deploy
description: Deploy the Searchlight IntegrationService to QA or PROD — a single front door over the repo's deploy scripts for any combination of the backend service, the admin UI, and the customer embed/website component. Asks which components and which environment, runs preflight (clean tree, Docker, AWS profile/region), enforces a hard PROD confirmation gate, then verifies the service reaches steady state + smoke passes and (for backend) the image replicates into prod's region (us-east-1). After a QA deploy, offers to run the acceptance-test (AT) pack against it. Use when asked to "deploy", "ship/release to qa|prod", "deploy the backend/admin/website", or "push a build to <env>".
---

# sl-deploy — deploy IntegrationService to QA or PROD

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. **Always `cd "$SL_BASE_PATH/IntegrationService"` first.** Unlike `sl-issue`, deploys run from the **real checkout, never a worktree** — the image tag is a commit SHA that must reproduce what's deployed.

This skill orchestrates the repo's own deploy scripts — it does not reimplement them. All AWS work uses **`AWS_PROFILE=searchlight`** (account 911229172008). **Region split is intentional: QA = us-west-2, PROD = us-east-1.** The scripts resolve region themselves (`export_resource_region`); your own verification `aws` calls must pass `--region` explicitly.

## The three components (and which script backs each)

| Component | What ships | Script |
|-----------|-----------|--------|
| **services** (backend) | Spring Boot API on ECS Fargate | `scripts/deploy-backend.sh <env>` |
| **admin** | React admin UI at the site root | `scripts/deploy-ui.sh <env>` |
| **website** | Lit customer embed/web-component under `/embed/` | `scripts/deploy-ui.sh <env>` |

> ⚠️ **admin and website ship together.** `deploy-ui.sh` always builds + publishes *both* the admin UI and the embed in one run — there is currently no flag to do one alone. So if the user picks **admin and/or website**, run `deploy-ui.sh <env>` **exactly once** (dedupe). Say this plainly when confirming the plan. (If they want true independent admin/embed deploys, that needs `--admin-only`/`--embed-only` flags added to `deploy-ui.sh` — offer it as a follow-up, don't fake it here.)

## Step 1 — Determine components + environment

If the user already named them ("deploy the backend to prod"), use that. Otherwise **ask** with `AskUserQuestion`:
- **Components** (multi-select): `services`, `admin`, `website`.
- **Environment** (single-select): `qa`, `prod`.

## Step 2 — Preflight (fail fast, before any slow build)

```bash
cd "$SL_BASE_PATH/IntegrationService"
export AWS_PROFILE=searchlight
aws sts get-caller-identity --query Account --output text    # must be 911229172008
git rev-parse --abbrev-ref HEAD && git status --porcelain     # branch + cleanliness
docker info >/dev/null 2>&1 && echo docker-up || echo DOCKER-DOWN
```

Requirements:
- **Account is 911229172008** — if not, stop (wrong profile; QA/PROD both live in the `searchlight` account, not default/driftwise).
- **PROD ⇒ clean working tree on `main`** (or the explicit release commit the user names). The image tag is `git rev-parse --short=12 HEAD`, so a dirty tree or wrong branch would mislabel the release. `deploy-backend.sh` refuses a dirty prod tree anyway — pre-check so you fail in 1 second, not after a build.
- **Docker daemon running** — backend `./gradlew check` (Testcontainers) and the UI `npm test` both need it. `deploy-backend.sh` also builds `linux/amd64`.
- **Infra applied for the env** — the scripts read deploy targets from Terraform outputs. If `terraform output` is empty for the env, the stack isn't applied; stop and say so.

## Step 3 — Confirm the plan

Print exactly what will happen: components → scripts, environment, the commit SHA (`git rev-parse --short=12 HEAD`), and for backend the current→new image (`current_service_image_tag`). 

**PROD is a hard gate.** `deploy-backend.sh`/`deploy-ui.sh` normally block on a typed phrase (`confirm_prod`) read from stdin — which a backgrounded tool call can't answer. So **this skill's explicit confirmation IS the human gate**:
1. Show the plan and get the user's explicit "yes, deploy to prod" (use `AskUserQuestion`, or an unambiguous typed yes).
2. **Only after that yes**, run the prod script with `DEPLOY_ASSUME_YES=1` (bypasses the stdin prompt).
3. **Never set `DEPLOY_ASSUME_YES=1` before an explicit per-deploy prod yes.** QA needs no such gate.

## Step 4 — Execute

Run each selected deploy **in the background** with logs to the scratchpad, and monitor (these take minutes: tests + build + push + apply + wait + smoke).

**Backend:**
```bash
# qa:
AWS_PROFILE=searchlight scripts/deploy-backend.sh qa            > <scratchpad>/deploy-backend-qa.log 2>&1
# prod (only after explicit yes):
DEPLOY_ASSUME_YES=1 AWS_PROFILE=searchlight scripts/deploy-backend.sh prod > <scratchpad>/deploy-backend-prod.log 2>&1
```
Useful flags: `--skip-build` (reuse an already-pushed/replicated SHA — the promote path, see Step 5), `--skip-webhook-smoke` (before the webhook receiver is live), `--acceptance` (post-deploy acceptance gate). `--skip-tests` is **refused for prod**.

**Admin / website (UI):** run once if either was selected.
```bash
AWS_PROFILE=searchlight scripts/deploy-ui.sh <env>   > <scratchpad>/deploy-ui-<env>.log 2>&1
```

Watch each log; on a non-zero exit surface the `[fail]` line. `deploy-backend.sh` already gates on `ecs wait services-stable` + smoke, so a green exit means the service came up. If the backend deploy fails smoke, the escape hatch is `scripts/rollback-backend.sh <env>` (points the service at the prior task-def revision, no rebuild).

## Step 5 — Verify (beyond what the scripts already assert)

**Service is up** — the script waited for steady state; add a public-URL health check and report it:
```bash
# prod: the custom domain; qa: the CloudFront api_url from tf output
curl -sS -o /dev/null -w '%{http_code}\n' https://searchlight-integrations.digital/actuator/health   # prod
```

**Backend image replicated into prod's region (#102)** — the ECR repo lives in us-west-2; a push (from *any* env's backend deploy) mirrors to us-east-1 so prod can pull. Confirm the SHA landed there (retry a few times — replication is async, usually seconds):
```bash
SHA="$(git -C "$SL_BASE_PATH/IntegrationService" rev-parse --short=12 HEAD)"
AWS_PROFILE=searchlight aws ecr describe-images \
  --repository-name integration-service-backend --region us-east-1 \
  --image-ids imageTag="$SHA" --query 'imageDetails[0].imagePushedAt' --output text
```
- **Deploying QA:** this proves the promote-to-prod path is ready — the same SHA is now in us-east-1, so a later `deploy-backend.sh prod --skip-build` can reuse it (no rebuild).
- **Deploying PROD:** `services-stable` already proved prod pulled it; this is a belt-and-suspenders confirmation.

## Step 6 — Acceptance tests (after a QA deploy, **offer**)

Once a **QA** deploy finishes green, **offer** to run the acceptance pack against it — don't run it unprompted (it takes minutes), and don't run it after a prod deploy (prod only gets the read-only `prod-smoke` subset, and only if the user asks). Recommend "yes" when the deploy included `services`.

If they accept, run `scripts/run-acceptance.sh qa`. It needs `ADMIN_API_KEY` + `WEBSITE_API_KEY` exported (it resolves the base URL from QA's Terraform outputs itself). Fetch both from QA's secrets first:
```bash
cd "$SL_BASE_PATH/IntegrationService"
export AWS_PROFILE=searchlight
export ADMIN_API_KEY="$(scripts/admin-key.sh qa)"
export WEBSITE_API_KEY="$(AWS_REGION=us-west-2 aws secretsmanager get-secret-value \
  --secret-id integration-service/qa/app/website-api-key --version-stage AWSCURRENT \
  --query SecretString --output text)"
scripts/run-acceptance.sh qa   > <scratchpad>/acceptance-qa.log 2>&1   # run in background; watch the log
```
Add `--push-contract` only if the webhook/push-ingestion contracts are deployed to QA (otherwise those scenarios stay skipped). Report the pass/fail summary; JUnit XML lands in `acceptance-tests/build/test-results/acceptanceTest/`.

> This is the same pack the deploy's own `--acceptance` flag runs as an inline gate. The difference: here it's a **post-deploy offer** so a normal QA deploy isn't blocked on it, and the user chooses per-deploy. If they'd rather gate every QA deploy, tell them to pass `--acceptance` (or set `DEPLOY_ACCEPTANCE=1`) in Step 4 instead.

## Step 7 — Report

State per component: env, commit SHA, current→new image, service health (HTTP code), and (backend) replication-to-us-east-1 status. Note the deployed URLs: prod API `https://searchlight-integrations.digital`, admin at the env `ui_url`, embed at `<ui_url>/embed/searchlight-integrations.js`. For a QA backend deploy, remind that the image is now promotable to prod with `--skip-build`.

## Guardrails
- Never deploy prod from a worktree, a dirty tree, or a non-`main` branch without the user naming the exact release commit.
- Never `--skip-tests` on prod (the scripts refuse it; don't try to route around).
- One `deploy-ui.sh` run covers admin+website — don't run it twice.
- Don't invent secrets, ECR repos, or regions — those are one-time bootstrap (app-secret seeding, ECR cross-region replication), not part of a routine deploy.
