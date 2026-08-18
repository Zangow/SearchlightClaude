---
name: sl-deploy
description: Deploy the Searchlight IntegrationService to QA or PROD — a single front door over the repo's deploy scripts for any combination of the backend service, the admin UI, and the customer embed/website component. Asks which components and which environment, runs preflight (clean tree, Docker, AWS profile/region), enforces a hard PROD confirmation gate, then verifies the service reaches steady state + smoke passes and (for backend) the image replicates into prod's region (us-east-1). A request that names BOTH environments is run as a promote sequence — QA deploy, then a MANDATORY acceptance-test (AT) gate against QA that must PASS before PROD is touched. Use when asked to "deploy", "ship/release to qa|prod", "deploy the backend/admin/website", or "push a build to <env>".
effort: medium
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

**Both environments = a promote sequence, not a choice.** If the request names both ("deploy to QA and PROD", "qa then prod", "roll this out everywhere"), do **not** ask them to pick one. Run it as an ordered sequence and say so when you confirm the plan:

```
QA deploy (Step 4) → QA verify (Step 5) → AT GATE against QA (Step 6, mandatory) → PROD yes → PROD deploy (Step 4) → PROD verify (Step 5)
```

Record that PROD is in the plan — **that flag is what makes Step 6 a blocking gate instead of an offer.** A red or un-run pack ends the run with QA deployed and PROD untouched.

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

**In a QA→PROD sequence, the prod yes comes *after* the AT gate.** Confirm the whole sequence here so the user knows both deploys are coming, but collect the hard prod confirmation **once Step 6 is green**, with the pack's pass/fail summary in front of them — a yes given before the tests ran isn't an informed one. A pre-gate "yes, do both" authorizes the *sequence*, never the prod leg on a red or un-run pack; don't carry it across the gate.

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

**Promote the tested image — don't rebuild it.** In a QA→PROD sequence the prod backend deploy must reuse the exact SHA the ATs ran against: `deploy-backend.sh prod --skip-build` (Step 5 already proved that SHA replicated into us-east-1). Re-check `git rev-parse --short=12 HEAD` is unchanged since the QA deploy before the prod leg; **if the tree moved, the AT gate is void** — redeploy QA and re-run Step 6 rather than promoting an untested SHA.

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

## Step 6 — Acceptance tests against QA (**mandatory gate when PROD is in the plan**)

Once a **QA** deploy finishes green, the acceptance pack runs against it. Whether that's a gate or an offer depends on where the run is headed:

| This run | AT pack | On failure |
|---|---|---|
| **QA → PROD** (both named) | **Always. No offer, no skip, no "the change is unrelated" exemption** | **Hard stop — PROD is not deployed** |
| **QA only** | **Offer** it (it takes minutes); recommend yes when the deploy included `services` | Report it; the user decides what's next |
| **PROD only** (no QA leg this run) | See *PROD without a QA leg* below | — |

`scripts/run-acceptance.sh qa` needs `ADMIN_API_KEY` + `WEBSITE_API_KEY` exported (it resolves the base URL from QA's Terraform outputs itself). Fetch both from QA's secrets first:
```bash
cd "$SL_BASE_PATH/IntegrationService"
export AWS_PROFILE=searchlight
export ADMIN_API_KEY="$(scripts/admin-key.sh qa)"
export WEBSITE_API_KEY="$(AWS_REGION=us-west-2 aws secretsmanager get-secret-value \
  --secret-id integration-service/qa/app/website-api-key --version-stage AWSCURRENT \
  --query SecretString --output text)"
scripts/run-acceptance.sh qa   > <scratchpad>/acceptance-qa.log 2>&1   # run in background; watch the log
```
Add `--push-contract` when the change touches webhook/push ingestion **and** those contracts are deployed to QA — without it those scenarios stay skipped.

**Reading the result — the gate opens on PASS and nothing else.**
- Non-zero exit / `ACCEPTANCE FAILED` → **FAIL**.
- **Could-not-run** (missing keys, Terraform/base-URL resolution failure, the pack erroring before any test executes) → **BLOCKED, and BLOCKED counts as FAIL for this gate.** "Didn't run" is never "nothing was wrong".
- **Green with skips** → report how many scenarios skipped and which. Push-ingestion scenarios self-skip without `--push-contract`, and the S3 delivery assertions self-skip without a resolvable `DELIVERY_S3_BUCKET` (the script exports it from Terraform — say so if that lookup failed). A silent skip reads as a pass and is exactly how a delivery guarantee goes unverified.
- Quote the real summary line and the JUnit path (`acceptance-tests/build/test-results/acceptanceTest/`) as evidence — not your recollection of the run.

**On FAIL or BLOCKED, stop the sequence.** State plainly: QA is deployed, **PROD is not**, and why — the failing scenarios plus the log path. Then hand it back. The paths forward are: fix → redeploy QA → re-run this gate, or `scripts/rollback-backend.sh qa`. **Do not deploy PROD on a red or un-run pack, and do not offer to** — if the user still wants prod after seeing the failures, that's a fresh, explicit prod-only instruction from them, never something this skill proposes, infers, or works around.

**PROD without a QA leg.** A prod-only request (hotfix, promoting a SHA from an earlier session, a rollback) has no QA gate to hang off. Don't invent one — but don't go quiet either: **before** the prod confirmation, say whether this SHA has a green QA AT run behind it. If you can't point to one, recommend the QA-first sequence instead and let the user decide; proceed only on their explicit yes. After a prod deploy the only pack that may run is the read-only `prod-smoke` subset (`scripts/run-acceptance.sh prod-smoke`), and only if asked — the full pack mutates data and must never be pointed at prod.

**Coverage caveat, say it rather than implying more than you ran.** The pack is black-box over the backend's HTTP + S3 surface, so an **admin/website-only** QA deploy is only indirectly covered by it. The gate still runs (a UI deploy can still break the flows the pack exercises), but for real browser coverage of the connect → register → deliver → unsubscribe loop, `scripts/run-e2e.sh qa` (Playwright, `e2e/specs/`) is the suite that exercises the UI — **offer** it on UI deploys; it is not part of the blocking gate.

> The same pack is available as an inline flag on the backend deploy (`--acceptance`, or `DEPLOY_ACCEPTANCE=1`), which fails the deploy outright if the pack fails. This skill runs it as an explicit step instead for two reasons: the gate must also hold for **UI-only** QA deploys, where `deploy-backend.sh` never runs at all; and the skill needs the result in hand to drive the prod confirmation. If you do use the flag, export both keys **before** the deploy — `run-acceptance.sh` dies without them, which would fail an otherwise-good deploy at its last step.

## Step 7 — Report

State per component: env, commit SHA, current→new image, service health (HTTP code), and (backend) replication-to-us-east-1 status. For any run that deployed QA, also report the **AT verdict** — PASS / FAIL / BLOCKED, counts (passed / failed / skipped), and whether it was the blocking gate or an optional offer. On a stopped sequence, lead with what is and isn't deployed: *"QA is on `<sha>`; PROD was not deployed — the AT gate failed on `<scenarios>`."* Note the deployed URLs: prod API `https://searchlight-integrations.digital`, admin at the env `ui_url`, embed at `<ui_url>/embed/searchlight-integrations.js`. For a QA backend deploy, remind that the image is now promotable to prod with `--skip-build`.

## Guardrails
- **Never deploy PROD in a QA→PROD run without a green AT pass against QA on the same SHA.** BLOCKED, un-run, or "it only skipped everything" is not green. This gate has no skip flag and no exemption for small or unrelated-looking changes — if you're about to write "the AT failure is unrelated to this change", stop and hand it to the user instead.
- Never deploy prod from a worktree, a dirty tree, or a non-`main` branch without the user naming the exact release commit.
- Never `--skip-tests` on prod (the scripts refuse it; don't try to route around).
- One `deploy-ui.sh` run covers admin+website — don't run it twice.
- Don't invent secrets, ECR repos, or regions — those are one-time bootstrap (app-secret seeding, ECR cross-region replication), not part of a routine deploy.
