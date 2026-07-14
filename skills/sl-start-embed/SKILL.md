---
name: sl-start-embed
description: Start a local test website that hosts the Searchlight customer embed (the <searchlight-integrations> Lit web component) pointed at a DEPLOYED environment — QA or PROD — then watch it and verify it actually comes up. Wraps scripts/sl-start-embed, which serves a local page carrying the component and same-origin-proxies /api + /oauth to that env's backend with the website API key injected server-side (so there's no CORS problem and no infra change). Use when asked to "start/kick off the embed", "open the embed against qa|prod", "test the web component on qa|prod", or "spin up the embed test page". NOT for the local dev stack — that's sl-start-env.
---

# sl-start-embed — host the customer embed against a deployed env, and verify it

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. **Always `cd "$SL_BASE_PATH/IntegrationService"` first.** This skill orchestrates the repo's own `scripts/sl-start-embed` — it does not reimplement it. All AWS work uses **`AWS_PROFILE=searchlight`** (account 911229172008); the script resolves per-env region itself.

This starts a **long-lived local server** (a proxy + test page), so run it **in the background** with logs to the scratchpad and then verify it came up — never block the turn on it. It targets a **deployed** backend (QA or PROD), so nothing local needs to be running; contrast `sl-start-env`, which boots the whole local stack.

## What the script does (so you can verify the right things)

`scripts/sl-start-embed <qa|prod>` resolves, from the same Terraform outputs / Secrets Manager the deploy scripts use:
- **API base** — QA: the `api_url` CloudFront front. PROD: no such front (`api_url` is null), so it defaults to the prod custom domain `https://searchlight-integrations.digital` (override with `--api-base` / `PROD_API_BASE`).
- **Embed bundle** — the env's deployed `/embed/searchlight-integrations.js` (or the local `ui-embed/dist` build with `--local`).
- **Website key** — injected server-side as `X-Website-Api-Key` (skip with `--no-key`).

It then serves `http://localhost:<port>` (default **8787**) and proxies `/api` + `/oauth` to that backend. The browser only ever talks to localhost — the cross-origin hop is server-side, which is why a plain localhost page (blocked by `WEBSITE_ALLOWED_ORIGINS`/CORS) can't do this but the proxy can.

## Step 1 — Environment + options

If the user named the env ("start the embed against qa"), use it. Otherwise **ask** with `AskUserQuestion`: `qa` or `prod`.

Options to thread through when relevant: `--port <n>` (if 8787 is busy), `--account <id>`, `--local` (test the local `ui-embed/dist` build instead of the deployed asset — build it first: `cd ui-embed && npm ci && npm run build`), `--api-base <url>` (a non-default backend), `--no-key`.

## Step 2 — PROD is a write gate

Pointed at **prod with the key injected, register/manage writes REAL production registrations.** So for prod:
- **Default to `--no-key`** (read-only: browse the catalog + UI, no mutations) unless the user explicitly wants to exercise registration against prod.
- If they *do* want a write-capable prod session, get an explicit "yes, write to prod" (`AskUserQuestion` or an unambiguous typed yes) **before** launching without `--no-key`.
- QA needs no such gate.

## Step 3 — Preflight (fast)

```bash
cd "$SL_BASE_PATH/IntegrationService"
export AWS_PROFILE=searchlight
aws sts get-caller-identity --query Account --output text     # expect 911229172008
command -v node aws terraform >/dev/null && echo tools-ok || echo MISSING-TOOL
lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1 && echo PORT-8787-BUSY || echo port-free
```
- Wrong account (not 911229172008) → stop (wrong profile; QA/PROD live in the `searchlight` account).
- **Port already busy** → a harness may already be up. Check it (`curl -s -o /dev/null -w '%{http_code}' http://localhost:8787/`); if it's ours, **reuse it and report the URL** rather than starting a duplicate. Otherwise pick another `--port`.

## Step 4 — Launch in the background + capture logs

```bash
SP="<scratchpad>"    # the session scratchpad dir
AWS_PROFILE=searchlight scripts/sl-start-embed <env> [options] > "$SP/sl-embed-<env>.log" 2>&1 &
```
Run it backgrounded so the server survives across the verification steps and the rest of the session. Record the PID so you can report how to stop it.

## Step 5 — Watch it and VERIFY it came up (the point of the skill)

Poll until the page answers, then assert the proxy path works. Don't declare success off the log alone — hit it:
```bash
PORT=8787   # or the chosen --port
for i in $(seq 1 30); do curl -s -o /dev/null -m 1 "http://localhost:$PORT/" && break; sleep 1; done
curl -sS -m 5  -o /dev/null -w 'page            -> HTTP %{http_code}\n' "http://localhost:$PORT/"
curl -sS -m 12 -o /dev/null -w 'proxied catalog -> HTTP %{http_code}\n' "http://localhost:$PORT/api/integrations"
grep -E '\[ ok \]|website key|proxy /api' "$SP/sl-embed-<env>.log"
```
Green = **page `200`** and **proxied `GET /api/integrations` `200`** (proves the page serves AND the proxy reaches the deployed backend with a working key). The startup log shows the resolved API base, embed bundle URL, and whether the website key was injected (`injected ✓`) or the session is read-only.

If it **doesn't** come up, surface the log — common causes: not the `searchlight` profile (secret/tf lookups fail), the env's Terraform stack not initialised/applied (`tf_output … unavailable`), an unbuilt local bundle with `--local`, or (prod) an unreachable/overridden API base. Don't loop blindly — report what the log says.

## Step 6 — Report

State: env, the URL to open (**`http://localhost:<port>`**), the resolved API base + embed bundle, key mode (injected vs read-only), and the verification results (page + proxied-catalog HTTP codes). Remind the user it **keeps running in the background** until stopped — give the stop command (`kill <pid>`, or `lsof -ti tcp:<port> | xargs kill`). For prod, restate that any register/manage action there is a real production write.

## Guardrails
- Never launch **prod with a key** without an explicit per-session "write to prod" yes; default prod to `--no-key`.
- Don't reimplement the resolution/proxy logic — always go through `scripts/sl-start-embed`.
- Don't start a duplicate on a busy port — reuse an already-running harness or pick another port.
- Background the server; never run it in the foreground (it blocks the turn until Ctrl-C).
