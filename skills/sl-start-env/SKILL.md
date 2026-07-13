---
name: sl-start-env
description: Boot the local Searchlight IntegrationService environment for testing — the Docker deps (Postgres 16 + LocalStack S3/SecretsMgr/SQS), the Spring Boot service under the local profile (port 8080, Flyway against the LOCAL DB), and/or the React admin UI and the Lit customer web-component (ui-embed) dev servers. Idempotent — checks what's already up and reuses it. Use before sl-verify / the acceptance pack, or when asked to "start the environment / run everything locally / spin up the local stack".
---

# sl-start-env — bring up the local IntegrationService environment

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. In worktree mode (`sl-issue` default) `SL_BASE_PATH` is repointed at the worktree root and `$SL_REAL_BASE` holds the true base — boot exactly as normal, just from the worktree checkout. `cd "$SL_BASE_PATH/IntegrationService"` before any command so this works regardless of where the skill was launched.

Single Spring Boot service backed by Dockerized Postgres + LocalStack, plus two Vite front-ends. **No SSM tunnels, no `fetch-env`, no shared-qa database** — every dependency runs on the local machine, so booting has no blast radius beyond this host. That is the key contrast with `dw-start-env`: **Flyway runs on startup against the *local* Postgres**, never a shared environment, so there is **no migration hard-block gate** — pending migrations just apply to the throwaway local DB. (If a migration ever looks wrong, that's a code review concern, not a boot blocker.)

Starts only the pieces the change needs. Run long-lived processes (`./gradlew bootRun`, `npm run dev`) **in the background** so they survive across verification steps, and capture their logs to the scratchpad. **Check what's already up before starting a duplicate.**

## Target argument

`backend` (default), `ui`, `embed`, or `all`. `ui`/`embed`/`all` imply `backend` (both front-ends point at the local API). Infer from the git diff when no target is given: a diff touching only `ui/` → `ui`; only `ui-embed/` → `embed`; otherwise `backend`.

## Preflight — what's already running (idempotent)

```bash
lsof -nP -iTCP:8080 -iTCP:5173 -sTCP:LISTEN      # app / Vite dev server already up?
docker compose -p integration-service ps          # postgres + localstack health
curl -sf localhost:8080/actuator/health/readiness && echo backend-ready
```
**Any port already LISTENing / any container healthy = reuse it; do not start a duplicate.**

## Worktree sessions — the env is a singleton, claim it first

The local env (ports 8080 / 4566 / 5432 / 5173 + the local Postgres) is a **singleton** — only one checkout may drive it at a time. Before the **first** boot of the session — worktree or not — claim the mutex:
```bash
WT="$SL_BASE_PATH/.claude/skills/_shared/sl-worktree.sh"    # in worktree mode use ${SL_REAL_BASE}/.claude/...
"$WT" env-claim --wait     # atomic lock; blocks until the env is free, then claims it for this checkout
```
`env-claim --wait` is a no-op when the env is free and when this session already holds it, so it's safe to call before every boot. A non-worktree session must still claim it, or it would boot over a worktree session's claim and defeat the singleton. **Release** once verification + PR are done: `"$WT" env-release` (`--force` clears a crashed session's lock).

## Backend  (`$SL_BASE_PATH/IntegrationService`)

Needed for **every** target — the front-ends talk to the local API. `cd "$SL_BASE_PATH/IntegrationService"` first.

1. **Docker deps** — Postgres 16 + LocalStack (S3, Secrets Manager, SQS). Start once; reuse if already healthy:
   ```bash
   docker compose up -d
   ```
   The `localstack-init/` ready.d hooks create the **delivery S3 bucket** (`integration-data-local`) and the **webhook SQS queue** on startup. Wait for both containers to report healthy before booting (`docker compose ps` → `healthy`) — the app fails fast if Postgres isn't reachable.

2. **Spring Boot service** under the `local` profile (the default via `spring.profiles.default`) — the **first (cold) boot of the session** only, as a long-lived background process with its log captured:
   ```bash
   ./gradlew bootRun     # run in the background; tee/redirect to <scratchpad>/bootRun.log
   ```
   Watch startup for compile errors, bean-wiring failures, and the Flyway migration summary. Then wait for readiness (poll, don't assume — cold start takes a few seconds):
   ```bash
   until curl -sf localhost:8080/actuator/health/readiness >/dev/null; do sleep 2; done; echo backend-ready
   ```
   `curl localhost:8080/actuator/health` gives the aggregate view (Postgres + S3 + SecretsManager + SQS all wired through LocalStack).

   **Local defaults that make the stack usable out of the box** (all overridable by env var — see `application-local.yml`):
   - Admin API key `local-admin-key` (header `X-Admin-Api-Key`); website API key `local-website-key` (header `X-Website-Api-Key`).
   - **Acceptance stub is enabled** (`ACCEPTANCE_STUB_ENABLED=true`), so `scripts/run-acceptance.sh local` and the push-contract scenarios run end-to-end against `localhost:8080` with no external mock.
   - CORS already allows the Vite dev servers (`http://localhost:5173`).

   **Iterating on backend code (no devtools).** There is no `spring-boot-devtools` on the classpath, so a code change means **stop and re-run `bootRun`** — Gradle recompiles the changed sources and cold-boots a fresh context. There is no in-place warm restart; keep the cold boot fast by leaving Docker deps up between rounds (never tear those down mid-session).

3. **Exercise it.** With the service up, the flagship end-to-end check is the acceptance pack against the local target (it does *not* boot the app itself — that's step 2's job):
   ```bash
   scripts/run-acceptance.sh local                    # core pack: registration→poll→S3 delivery, admin lifecycle, catalog authZ, dry-run, idempotency
   scripts/run-acceptance.sh local --push-contract    # + partner-POST / partner-S3 / webhook / OAuth-reauth push contracts
   ```
   Or hit the REST surface by hand: admin APIs (integrations, partner credentials, webhook events, registration ops), customer APIs (catalog, registration, OAuth connect/callback), and webhook ingest — mapped output lands in the LocalStack `integration-data-local` bucket.

## Admin UI  (`$SL_BASE_PATH/IntegrationService/ui`)

React + Vite SPA (issue #17). `cd "$SL_BASE_PATH/IntegrationService/ui"` first.

1. Ensure the backend (above) is up — the UI points at the local API.
2. **`.env.local`** supplies the local API base; create it once from the template if absent:
   ```bash
   test -f .env.local || cp .env.example .env.local     # sets VITE_API_BASE_URL=http://localhost:8080
   ```
3. `npm install` if `node_modules` is missing/stale, then **`npm run dev`** in the background (Vite, http://localhost:5173). Confirm it compiled with no server/runtime errors.
4. For browser-driven verification, confirm a browser is connected via the Claude-in-Chrome / chrome-devtools MCP (load with ToolSearch; if the extension isn't connected, ask the user to connect it).

## Customer web component  (`$SL_BASE_PATH/IntegrationService/ui-embed`)

Lit + TypeScript embeddable `<searchlight-integrations>` component with a demo page (issue #22). `cd "$SL_BASE_PATH/IntegrationService/ui-embed"` first.

1. Ensure the backend is up. `npm install` if stale, then **`npm run dev`** in the background (Vite). The `demo/index.html` page renders the component against the local API.
2. **Port note:** both front-ends default to Vite's 5173. If `ui` is already on 5173, Vite auto-increments `ui-embed` to 5174 — note the actual port in the report. The backend's local CORS allow-list is `5173` only; if the embed lands on another port, override `WEBSITE_ALLOWED_ORIGINS` on the backend (env var) to include it before the demo can call the API cross-origin.

## Report back

List what was started with each background process's **log location and ready/not-ready status**, plus anything already running that was reused. Include the concrete URLs/ports (backend `:8080`, UI `:5173`, embed `:5173`/`:5174`) and note whether the env claim is held (so `sl-verify` / a later step knows to release it). Then hand control to the relevant verification step (`sl-verify`, or the acceptance pack).
