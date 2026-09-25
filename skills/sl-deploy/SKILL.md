---
name: sl-deploy
description: Deploy the Searchlight IntegrationService to QA or PROD — a single front door over the repo's deploy scripts for any combination of the backend service, the admin UI, and the customer embed/website component. Asks which components and which environment, runs preflight (clean tree, Docker, AWS profile/region), enforces a hard PROD confirmation gate, then verifies the service reaches steady state + smoke passes and (for backend) the image replicates into prod's region (us-east-1). A request that names BOTH environments is run as a promote sequence — QA deploy, then a MANDATORY acceptance-test (AT) gate against QA that must PASS before PROD is touched. Use when asked to "deploy", "ship/release to qa|prod", "deploy the backend/admin/website", or "push a build to <env>".
effort: medium
---

# sl-deploy — deploy IntegrationService to QA or PROD

> **Repo paths use `$SL_BASE_PATH`** — resolve it per `_shared/base-path.md`, **including its `sl-deploy` exception** (deploys run from the real checkout — Guardrail 2). **Always `cd "$SL_BASE_PATH/IntegrationService"` first.**

This skill orchestrates the repo's own deploy scripts — it does not reimplement them. All AWS work uses **`AWS_PROFILE=searchlight`** (account 911229172008). **Region split is intentional: QA = us-west-2, PROD = us-east-1.** The scripts resolve region themselves (`export_resource_region`); your own verification `aws` calls must pass `--region` explicitly.

**The standing rules live once, numbered, in [Guardrails](#guardrails) at the end.** The steps below are the procedure and cite a rule by number rather than restating it — read the Guardrails before Step 1.

## The three components (and which script backs each)

| Component | What ships | Script |
|-----------|-----------|--------|
| **services** (backend) | Spring Boot API on ECS Fargate | `scripts/deploy-backend.sh <env>` |
| **admin** | React admin UI at the site root | `scripts/deploy-ui.sh <env>` |
| **website** | Lit customer embed/web-component under `/embed/` | `scripts/deploy-ui.sh <env>` |

> ⚠️ **admin and website ship together.** `deploy-ui.sh` always builds + publishes *both* the admin UI and the embed in one run — there is no flag to do one alone, so picking **admin and/or website** means one `deploy-ui.sh <env>` run (Guardrail 6). Say this plainly when confirming the plan. (Truly independent admin/embed deploys need `--admin-only`/`--embed-only` flags added to `deploy-ui.sh` — offer it as a follow-up, don't fake it here.)

## Step 1 — Determine components + environment

If the user already named them ("deploy the backend to prod"), use that. Otherwise **ask** with `AskUserQuestion`:
- **Components** (multi-select): `services`, `admin`, `website`.
- **Environment** (single-select): `qa`, `prod`.

**Both environments = a promote sequence, not a choice.** If the request names both ("deploy to QA and PROD", "qa then prod", "roll this out everywhere"), do **not** ask them to pick one. Run it as an ordered sequence and say so when you confirm the plan:

```
QA deploy (Step 4) → QA verify (Step 5) → AT GATE against QA (Step 6, mandatory) → PROD yes → PROD deploy (Step 4) → PROD verify (Step 5)
```

Record that PROD is in the plan — **that flag is what makes Step 6 a blocking gate instead of an offer** (Guardrail 1).

## Step 2 — Bring `main` up to date, then preflight (fail fast, before any slow build)

The deploy scripts build the **working tree**, not `origin/main`, so a local `main` behind `origin` silently ships old code. Fast-forward it first, **once, here** — never again later in the run (Guardrail 4):

```bash
cd "$SL_BASE_PATH/IntegrationService"
echo "pre-pull: $(git rev-parse --short=12 HEAD)"
if ! git fetch origin; then echo "FETCH FAILED"
elif [ "$(git rev-parse --abbrev-ref HEAD)" = main ]; then git pull --ff-only || echo "PULL FAILED"; fi
git rev-parse --abbrev-ref HEAD && git status --porcelain     # branch + cleanliness
git rev-list --left-right --count origin/main...HEAD          # "<behind> <ahead>" vs origin/main
export AWS_PROFILE=searchlight
aws sts get-caller-identity --query Account --output text     # must be 911229172008
docker info >/dev/null 2>&1 && echo docker-up || echo DOCKER-DOWN
```

Read the markers, not the exit code (the last command's status hides the fetch and the pull):
- **`FETCH FAILED`** — stop: you can't tell what you'd be shipping.
- **On `main`, the pull moved `HEAD`** (the `pre-pull:` SHA differs from `HEAD` now) — if the request was to promote a specific, already-tested SHA (e.g. "ship what's on QA to prod"), the pull has just swapped it for newer, untested commits: say so in the Step 3 plan and let the user choose — deploying the new `HEAD` is a QA-first sequence, not a promote.
- **On `main`, `PULL FAILED`** (a `main` diverged from `origin`, or a dirty tree blocking the fast-forward) — stop and say why. Never merge, rebase, stash or reset to make it pass. A non-zero *ahead* count after a clean pull is unpushed local commits on `main` — call it out in the Step 3 plan.
- **Not on `main`** (a branch or detached `HEAD`) — nothing is pulled; the user is deploying that checkout on purpose. Record the branch and both counts; a non-zero *behind* goes in the Step 3 plan. PROD from here needs the user to have named that exact commit (Guardrail 2).

Then:
- **Account is 911229172008** — if not, stop (wrong profile; QA/PROD both live in the `searchlight` account, not default/driftwise).
- **PROD ⇒ the tree satisfies Guardrail 2.** `deploy-backend.sh` refuses a dirty prod tree anyway — pre-check so you fail in 1 second, not after a build.
- **Docker daemon running** — backend `./gradlew check` (Testcontainers) and the UI `npm test` both need it. `deploy-backend.sh` also builds `linux/amd64`.
- **Infra applied for the env** — the scripts read deploy targets from Terraform outputs. If `terraform output` is empty for the env, the stack isn't applied; stop and say so.
- **MFA session, when `services` is in the plan** (Guardrail 9). Ask the user for one 6-digit TOTP code now, then mint the session into a mode-600 file that every backend leg sources (shell state does not survive between Bash calls):
  ```bash
  SERIAL="$(AWS_PROFILE=searchlight aws iam list-mfa-devices \
    --query "sort_by(MFADevices[?contains(SerialNumber, ':mfa/')], &EnableDate)[-1].SerialNumber" --output text)"
  ( set -o pipefail; umask 077; AWS_PROFILE=searchlight aws sts get-session-token --serial-number "$SERIAL" \
      --token-code <TOTP> --duration-seconds 43200 \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text \
    | awk 'NF==3 {printf "export AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s\n",$1,$2,$3}' \
    > <scratchpad>/mfa.env ) && [ -s <scratchpad>/mfa.env ] && echo MFA-OK || echo "MFA FAILED"
  ```
  Proceed only on `MFA-OK`. On `MFA FAILED` the file is empty, and a backend leg that sources it then runs with **no** credentials (it unsets `AWS_PROFILE`), failing as a misleading `terraform init failed` — so re-mint first. `invalid MFA one time pass code` = the digits were wrong (ask for a fresh code); `InvalidClientTokenId` = stale session vars in the shell, not MFA; a `SERIAL` of `None` = no `:mfa/` device resolved. 12 h covers a whole QA → AT → PROD sequence.

## Step 3 — Confirm the plan

Print exactly what will happen: components → scripts, environment, the commit SHA (`git rev-parse --short=12 HEAD`), the Step 2 branch/ahead/behind status, and for backend the current→new image (`current_service_image_tag`).

**PROD is a hard gate** (Guardrail 3). `deploy-backend.sh`/`deploy-ui.sh` normally block on a typed phrase (`confirm_prod`) read from stdin — which a backgrounded tool call can't answer. So **this skill's explicit confirmation IS the human gate**:
1. Show the plan and get the user's explicit "yes, deploy to prod" (use `AskUserQuestion`, or an unambiguous typed yes).
2. **Only after that yes**, run the prod script with `DEPLOY_ASSUME_YES=1` (bypasses the stdin prompt). QA needs no such gate.

**In a QA→PROD sequence**, confirm the whole sequence here so the user knows both deploys are coming, but collect the prod yes **once Step 6 is green**, with the pack's pass/fail summary in front of them (Guardrail 3).

## Step 4 — Execute

Run each selected deploy **in the background** with logs to the scratchpad, and wait on it per `_shared/waiting.md` — rc wrapper + bounded poll slices (these take minutes: tests + build + push + apply + wait + smoke).

**Order within an env: backend first, UI second, never overlapping the backend's test phase** (Guardrail 7). Start `deploy-backend.sh`; start `deploy-ui.sh` only once your poll slice sees `grep -q 'tests passed' <backend log>` (the script's `[ ok ] tests passed` line) or the backend's `rc` has landed. A UI-only run starts straight away.

**Backend** — each leg in its own subshell, MFA session loaded and the app env scrubbed (Guardrails 8, 9):
```bash
# qa:
( . <scratchpad>/mfa.env && unset AWS_PROFILE AWS_REGION AWS_ENDPOINT_URL ADMIN_API_KEY WEBSITE_API_KEY INTERNAL_API_KEY DB_URL &&
  scripts/deploy-backend.sh qa ) > <scratchpad>/deploy-backend-qa.log 2>&1
# prod (only after the explicit yes — Guardrail 3). --skip-build: the SHA is already pushed (Guardrail 4);
# drop it only when Step 5's describe-images finds no image for this SHA (a prod-only deploy of a never-built commit):
( . <scratchpad>/mfa.env && unset AWS_PROFILE AWS_REGION AWS_ENDPOINT_URL ADMIN_API_KEY WEBSITE_API_KEY INTERNAL_API_KEY DB_URL &&
  DEPLOY_ASSUME_YES=1 scripts/deploy-backend.sh prod --skip-build ) > <scratchpad>/deploy-backend-prod.log 2>&1
```
Flags:
- `--skip-build` — reuse an already-pushed image for this SHA (Guardrail 4). Confirm the tag exists first with the Step 5 `describe-images` call.
- `--skip-webhook-smoke` — pass it unless `ACCEPTANCE_TOKEN` is set. Without that token the webhook smoke fails **after** the apply, with a stale "#25 not deployed" message and a `consider rollback` line — the env is deployed and fine. Core smoke (health + catalog) still runs; the AT pack covers webhooks for real.
- `--skip-tests` — refused on prod (Guardrail 5).
- `--acceptance` — don't use it here; Step 6 runs the pack instead (see the note at the end of Step 6).

In a QA→PROD sequence, re-check `git rev-parse --short=12 HEAD` is unchanged since the QA deploy before starting the prod leg (Guardrail 4).

**Admin / website (UI)** — once per env (Guardrail 6), after the backend's tests (Guardrail 7):
```bash
( unset AWS_REGION AWS_ENDPOINT_URL && AWS_PROFILE=searchlight scripts/deploy-ui.sh <env> ) > <scratchpad>/deploy-ui-<env>.log 2>&1
# prod: prefix DEPLOY_ASSUME_YES=1 — only after the explicit yes (Guardrail 3)
```

When each `rc` lands, read it (not a trailing `tail`'s exit code); on non-zero surface the log's `[fail]` line. `deploy-backend.sh` already gates on `ecs wait services-stable` + smoke, so a green exit means the service came up. If the backend fails smoke, **verify before you roll back** — `/actuator/health`, `/actuator/health/readiness`, and `aws ecs describe-services` showing one deployment on the expected image tag; a failure the message blames on smoke alone is not proof the service is down. The escape hatch for a genuinely broken deploy is `scripts/rollback-backend.sh <env>` (points the service at the prior task-def revision, no rebuild).

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
- **Deploying QA:** this proves the promote-to-prod path is ready — the same SHA is now in us-east-1, so the prod leg can reuse it with `--skip-build` (Guardrail 4).
- **Deploying PROD:** `services-stable` already proved prod pulled it; this is a belt-and-suspenders confirmation.

## Step 6 — Acceptance tests against QA (**mandatory gate when PROD is in the plan**)

Once a **QA** deploy finishes green, the acceptance pack runs against it. Whether that's a gate or an offer depends on where the run is headed:

| This run | AT pack | On failure |
|---|---|---|
| **QA → PROD** (both named) | **Always** — no offer, no skip (Guardrail 1) | **Hard stop — PROD is not deployed** |
| **QA only** | **Offer** it (it takes minutes); recommend yes when the deploy included `services` | Report it; the user decides what's next |
| **PROD only** (no QA leg this run) | See *PROD without a QA leg* below | — |

`scripts/run-acceptance.sh qa` needs `ADMIN_API_KEY` + `WEBSITE_API_KEY` exported (it resolves the base URL from QA's Terraform outputs itself). Fetch both from QA's secrets **in the shell that runs the pack, never a deploy shell** (Guardrail 8):
```bash
cd "$SL_BASE_PATH/IntegrationService"
export AWS_PROFILE=searchlight
export ADMIN_API_KEY="$(scripts/admin-key.sh qa)"
export WEBSITE_API_KEY="$(AWS_REGION=us-west-2 aws secretsmanager get-secret-value \
  --secret-id integration-service/qa/app/website-api-key --version-stage AWSCURRENT \
  --query SecretString --output text)"
scripts/run-acceptance.sh qa   > <scratchpad>/acceptance-qa.log 2>&1   # background + poll per _shared/waiting.md
```
Add `--push-contract` when the change touches webhook/push ingestion **and** those contracts are deployed to QA — without it those scenarios stay skipped.

**Reading the result — the gate opens on PASS and nothing else** (Guardrail 1).
- Non-zero exit / `ACCEPTANCE FAILED` → **FAIL**.
- **Could-not-run** (missing keys, Terraform/base-URL resolution failure, the pack erroring before any test executes) → **BLOCKED**, which this gate treats as FAIL.
- **Green with skips** → report how many scenarios skipped and which. Push-ingestion scenarios self-skip without `--push-contract`, and the S3 delivery assertions self-skip without a resolvable `DELIVERY_S3_BUCKET` (the script exports it from Terraform — say so if that lookup failed). A silent skip reads as a pass and is exactly how a delivery guarantee goes unverified.
- Quote the real summary line and the JUnit path (`acceptance-tests/build/test-results/acceptanceTest/`) as evidence — not your recollection of the run.

**On FAIL or BLOCKED, stop the sequence.** State plainly: QA is deployed, **PROD is not**, and why — the failing scenarios plus the log path. Then hand it back. The paths forward are: fix → redeploy QA → re-run this gate, or `scripts/rollback-backend.sh qa`. Proposing, inferring or working around a prod leg from here is off the table (Guardrail 1).

**PROD without a QA leg.** A prod-only request (hotfix, promoting a SHA from an earlier session, a rollback) has no QA gate to hang off. Don't invent one — but don't go quiet either: **before** the prod confirmation, say whether this SHA has a green QA AT run behind it. If you can't point to one, recommend the QA-first sequence instead and let the user decide; proceed only on their explicit yes. After a prod deploy, the read-only `prod-smoke` subset (`scripts/run-acceptance.sh prod-smoke`) may run if asked (Guardrail 11).

**Coverage caveat, say it rather than implying more than you ran.** The pack is black-box over the backend's HTTP + S3 surface, so an **admin/website-only** QA deploy is only indirectly covered by it. The gate still runs (a UI deploy can still break the flows the pack exercises), but for real browser coverage of the connect → register → deliver → unsubscribe loop, `scripts/run-e2e.sh qa` (Playwright, `e2e/specs/`) is the suite that exercises the UI — **offer** it on UI deploys; it is not part of the blocking gate.

> The same pack is available as an inline flag on the backend deploy (`--acceptance`, or `DEPLOY_ACCEPTANCE=1`), which fails the deploy outright if the pack fails. **This skill does not use it:** the flag needs `ADMIN_API_KEY` + `WEBSITE_API_KEY` exported into the deploy shell, which breaks the deploy's own test phase (Guardrail 8); the gate must also hold for **UI-only** QA deploys, where `deploy-backend.sh` never runs; and the skill needs the result in hand to drive the prod confirmation.

## Step 7 — Report

State per component: env, commit SHA, current→new image, service health (HTTP code), and (backend) replication-to-us-east-1 status. For any run that deployed QA, also report the **AT verdict** — PASS / FAIL / BLOCKED, counts (passed / failed / skipped), and whether it was the blocking gate or an optional offer. On a stopped sequence, lead with what is and isn't deployed: *"QA is on `<sha>`; PROD was not deployed — the AT gate failed on `<scenarios>`."* Note the deployed URLs: prod API `https://searchlight-integrations.digital`, admin at the env `ui_url`, embed at `<ui_url>/embed/searchlight-integrations.js`. For a QA backend deploy, remind that the image is now promotable to prod with `--skip-build`. Delete `<scratchpad>/mfa.env` once the run is over.

## Guardrails

Each standing rule lives here once; the steps cite it by number.

1. **The QA AT gate.** Never deploy PROD in a QA→PROD run without a green AT pass against QA on the same SHA. BLOCKED, un-run, or "it only skipped everything" is not green, and a red or un-run pack ends the run with QA deployed and PROD untouched. This gate has no skip flag and no exemption for small or unrelated-looking changes — if you're about to write "the AT failure is unrelated to this change", stop and hand it to the user instead. Don't deploy PROD on a red or un-run pack and don't offer to; if the user still wants prod after seeing the failures, that's a fresh, explicit prod-only instruction from them, never something this skill proposes, infers, or works around.
2. **PROD ships from the real checkout, clean, on `main`.** Never deploy prod from a worktree, a dirty tree, or a non-`main` branch unless the user named that exact release commit. The image tag is `git rev-parse --short=12 HEAD`, so anything else mislabels the release.
3. **PROD needs an explicit, per-deploy, informed yes.** Never set `DEPLOY_ASSUME_YES=1` before it. In a QA→PROD run the yes comes **after** the AT gate is green, with its summary in front of the user — a pre-gate "yes, do both" authorizes the *sequence*, never the prod leg on a red or un-run pack; don't carry it across the gate.
4. **One SHA, built once, promoted as-is.** Both envs share one ECR repo with immutable tags, so an env receiving a SHA that's already pushed deploys it with `--skip-build` — a rebuild dies at `docker push`, and would be an untested twin anyway (builds aren't bit-reproducible). In a QA→PROD run the prod leg reuses the exact SHA the ATs ran against: `main` is pulled once, in Step 2, never between legs, and if `HEAD` moved since the QA deploy the AT gate is void — redeploy QA and re-run Step 6 rather than promoting an untested SHA.
5. **Never `--skip-tests` on prod.** The scripts refuse it; don't route around that.
6. **One `deploy-ui.sh` run per env** covers admin + website — don't run it twice.
7. **Never run `deploy-ui.sh` while `deploy-backend.sh` is in its test phase.** The UI script's `npm ci` rewrites `ui/node_modules`, which `./gradlew check`'s `PollRunDurationGuardContractTest` walks — the backend then fails with `NoSuchFileException` under `ui/node_modules` and stops before ECS, leaving the env half-deployed. Start the UI deploy only after the backend log prints `[ ok ] tests passed` (or the backend exits). This holds across envs and for any `npm ci`/`npm install` in `ui/` — and a prod leg with `--skip-build` still runs `check`. (One Gradle run per checkout: `_shared/waiting.md` Rule D.)
8. **The deploy shell carries no app or endpoint env.** Never export `ADMIN_API_KEY`, `WEBSITE_API_KEY`, `INTERNAL_API_KEY`, `DB_URL` or `AWS_ENDPOINT_URL` into the shell that runs `deploy-backend.sh` — the test JVM inherits them (`ADMIN_API_KEY` alone 401s ~160 integration tests; `AWS_ENDPOINT_URL` fails the run-acceptance script tests). Don't pre-export `AWS_REGION` either: the scripts prefer it over the env's own region. Fetch app keys only in the shell that runs the AT pack. A mass multi-class failure in the deploy's test phase right after a green `check` on the same SHA is environment, not a regression.
9. **Mint the MFA session before the first ECR push.** A force-MFA policy denies ECR push/pull to non-MFA credentials, and `ecr get-login-password`/`docker login` succeed anyway — only the push proves it, so a `docker push` `403 Forbidden` means the session is missing or expired: don't debug Docker or retry the same credentials. Only the user can produce the TOTP code, so ask once, up front, for any run that includes `services`; resolve the device serial with `list-mfa-devices`, never hand-write it; run the scripts on the session vars with `AWS_PROFILE` unset.
10. **Don't invent secrets, ECR repos, or regions** — those are one-time bootstrap (app-secret seeding, ECR cross-region replication), not part of a routine deploy.
11. **The full AT pack never runs against prod** — it mutates data. After a prod deploy only the read-only `prod-smoke` subset may run, and only if asked.
