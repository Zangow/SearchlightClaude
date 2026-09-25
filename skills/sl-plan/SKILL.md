---
name: sl-plan
description: Planning-only front door that turns a Searchlight IntegrationService GitHub issue into a proper, reviewed implementation plan and persists it on the card — pulls the issue via gh, grounds itself in the real IntegrationService code (file:line, not guesses), works through the clarifying questions WITH you interactively, authors a step-by-step plan, runs it past a fresh plan-review panel, then writes it back to the issue as a comment (default) or an appended description section. Records the Searchlight-specific footprint every ticket needs — config-only vs platform capability, Flyway migration, backend/UI/embed/infra deploy, and which live integration configs must be republished afterwards. The persisted plan becomes the plan of record a later sl-issue follows instead of re-planning from scratch. Use when asked to "plan this issue / write a plan for #n / think through this ticket before we build it / put a plan on the card". Writes no code, cuts no branch, opens no PR.
effort: high
---

# sl-plan — GitHub issue → a reviewed plan, persisted on the card (Searchlight)

> **Repo paths use `$SL_BASE_PATH`** — resolve it per `_shared/base-path.md`.

The planning front door alongside **`sl-issue`** (issue → shipped PR). Its single job is **the plan**: understand the ticket, ground it in the actual code, resolve the unknowns **with the user**, get the plan independently reviewed, and **persist it on the GitHub issue** so the thinking survives this session.

That persistence is the point. Today an `/sl-issue` run re-derives the plan in its own context and the reasoning evaporates when the session ends. After `/sl-plan`, the plan lives on the card — you can read it, edit it, argue with it, and hand it to a later `/sl-issue` (or a teammate) as the **plan of record**.

**It writes no feature code, cuts no branch, boots no env, opens no PR, and never moves the card.** Its only writes are to the GitHub issue, and those are user-gated.

**Autonomy boundary — inverted vs `sl-issue`.** `sl-issue` treats a clarifying question as an exception ("only ambiguities that change *what* gets built"). Here, **clarification is the main event**: this is explicitly the place where you and Claude hash out the ambiguities before any work kicks off. Ask freely (batched, concrete), and record every answer on the card. The one thing that stays gated at the end is the *write* — you confirm before anything lands on a human's ticket.

## Inputs

```
/sl-plan <issue-number|url> [--dry-run] [--replan]
```
- An issue URL (`https://github.com/Zangow/IntegrationService/issues/<n>`) **or just an issue number** — `159` or `#159`. A bare number **defaults to `Zangow/IntegrationService`**, where every Searchlight card lives. If no issue was given, ask for it.
- **`--dry-run`** — plan and report to the terminal only. **No** comment, **no** body edit. Use to think a ticket through without committing anything to it.
- **`--replan`** — the card already carries an `sl-plan` comment and you want a fresh one anyway (scope changed, the old plan is wrong). Without it, an existing plan is **revised**, not duplicated (step 1).

## Pipeline

### 1. Fetch the issue
Pull everything that could carry a requirement — the body *and* the comment thread (real acceptance criteria, prior clarifications, and owner rulings live in comments on this board):
```bash
gh issue view <n> --repo Zangow/IntegrationService \
  --json number,title,body,labels,assignees,comments,url,state,milestone,createdAt
```
Capture the issue `number` and `url`. Note linked issues / `Depends on` / task-list sub-items, and any **epic** the card hangs off (`#1` platform epic, `#129` raw-capture, `#134` Yelp docs-compliance …) — sibling tickets in the same epic usually set the pattern to follow.

Then check two things on the card before planning anything:
1. **An existing `sl-plan` comment** (look for the `## 🧭 Implementation plan — sl-plan` heading). If one exists and `--replan` wasn't passed, you are **revising** it: read it, treat its resolved clarifications as already-settled (don't re-ask them), and in step 6 post a **revision** that links the prior comment rather than a duplicate plan.
2. **The card's board column** — useful context for how much rigor the plan warrants, and reported at the end:
   ```bash
   OWNER="Zangow"; PROJECT_NAME="Searchlight Integration Service"
   URL="https://github.com/Zangow/IntegrationService/issues/<n>"
   PNUM="$(gh project list --owner "$OWNER" --format json \
     --jq ".projects[] | select(.title==\"$PROJECT_NAME\") | .number")"
   gh project item-list "$PNUM" --owner "$OWNER" --format json --limit 5000 \
     --jq "[.items[] | select(.content.url==\"$URL\")] | (.[0].status // \"(not on board)\")"
   ```

**This skill never moves the card and never assigns it.** Planning isn't starting work — the card stays exactly where it sits (`Backlog` / `Ready`), and `sl-issue` moves it to "In progress" when the real work kicks off.

### 2. Ground the plan in the actual codebase  ← before writing a single planning word
A plan that names no files is a wish. Find the real surfaces this ticket touches — each grounding pass (inline, or an `Explore` agent: Agent tool, `subagent_type: Explore`) returns **`file:line` anchors and the existing pattern to follow**, not prose. The candidate surfaces:

- **Backend** — `$SL_BASE_PATH/IntegrationService/src/main/java/io/searchlightdigital/integration/` (`api` · `domain` · `mapping` · `hydration` · `polling` · `delivery` · `config`)
- **Schema** — `src/main/resources/db/migration/V*.sql` (Flyway, **additive-only**, `ddl-auto: validate`)
- **Admin UI** — `IntegrationService/ui/`
- **Customer embed** — `IntegrationService/ui-embed/` (Lit web component)
- **Infra** — `IntegrationService/infra/` (Terraform; IAM task-role policies live here and are a recurring blocker — see the risk list in step 4)
- **Ops / deploy** — `IntegrationService/scripts/`
- **Tests** — `src/test/`, `src/integrationTest` equivalents, `acceptance-tests/`, `e2e/`

**Cap the fan-out at 3.** Decide which surfaces are plausible first, and skip the ones the ticket obviously doesn't touch. **One or two plausible surfaces → ground them inline** on this thread (Grep / Glob / `git ls-files` / Read); dispatch nothing. **Three or more → fresh `Explore` agents in one message, never more than 3**, one per plausible group: **Backend + Schema**, **Admin UI + Embed**, **Infra + Ops** — Tests ride with the surface they test. Never dispatch a fourth; widen an agent's brief instead.

Ask each pass for: where this behavior lives today, the **closest existing implementation to copy** (the house pattern beats a novel one), what would have to change, what's already there that the ticket may not know about, and where the matching tests live.

**Also settle the config-vs-code question here** — it is the single most consequential fork on this codebase. Determine whether the ticket is:
- **config-only** — expressible in an integration config (endpoints, mappings, transforms, hydration, jq) against capabilities the deployed backends **already** have → no backend deploy; or
- **a platform capability gap** — it needs a new general capability in the service. If so, name it, and note it must be **GENERAL** (reusable across integrations), that QA/PROD backends won't have it until deployed, and that any config depending on it can't be published before that deploy.

Check whether the ticket has already been overtaken by events (a recent commit/PR may have partly done it). If it looks substantially done, say so **before** planning.

### 3. Clarify — with the user, interactively  ← the reason this skill exists
Distill the issue into what you'd need to build it, then find the gaps. Ask about anything that changes **what** gets built, or that changes the plan **materially** (an approach fork with real trade-offs is worth asking about here, even though `sl-issue` would decide it silently — the whole point is that you're in the room).

Use `AskUserQuestion`, **batched** (up to 4 questions per call, concrete options, your recommendation first and labelled "(Recommended)"). Prefer two rounds of real questions over ten one-at-a-time pings. Gaps worth resolving on this codebase:

- **Scope boundaries** — which integrations/categories/ingestion modes (POLL vs WEBHOOK) are in vs. out
- **Config vs capability** — if it *could* be done either way, which does the owner want? (A capability change means a backend deploy to both envs; a config change means republishing live configs.)
- **Behavior at the edges** — empty payloads, partial/failed hydration, duplicate or superseded records, unmapped required fields, credential expiry, rate limits, retries, fail-open vs fail-closed
- **Contract & data** — new canonical/standard-schema fields (these need owner + ingestion-owner sign-off — see the guardrails), nullability, whether existing delivered data needs a backfill or remap, whether the API shape is breaking
- **Blast radius on live data** — does this touch already-delivered S3 objects (remap, purge, redaction, versioning)? Say exactly what happens to existing keys.
- **Definition of done** — what the user wants to *see* working, and **in which environment** (local · QA · PROD), before this counts as finished

Don't ask what you can read: resolve anything the code already answers via step 2 instead of spending a question on it. Never ask about pure implementation mechanics you should just decide.

**Record every answer.** Resolved clarifications go into the plan's *Resolved clarifications* section (step 4) and land on the card in step 6 — so the ticket, not this transcript, is the source of truth.

### 4. Author the plan — inline, on this thread
Write the plan yourself; do not dispatch a planning agent — it would re-read everything you just grounded and hand back a plan you then have to re-own. Every step names a real `file:line` from the step-2 grounding.

Write it to a stable, non-repo path so nothing lands in the repo's history and downstream skills can read it:
```
${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-plan/PLAN-<n>.md
```
Also write the **requirements checklist** to the exact path `sl-issue` already expects, so a later run inherits it instead of re-deriving it:
```
${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md
```
(Both are local **working copies** — the comment posted in step 6 is the durable source of truth, because a later run may happen on a different machine or in a worktree. Keep the checklist table inline in the comment for exactly that reason.)

**Plan template** (this is what gets posted in step 6):
```markdown
## 🧭 Implementation plan — sl-plan <YYYY-MM-DD>

**Change type:** <config-only | platform capability (GENERAL) | both> ·
**Surfaces:** <backend · admin UI · embed · infra · scripts> ·
**Flyway migration:** <yes — V<n>__<name>.sql, additive | no> ·
**Deploy needed:** <none | backend QA+PROD | UI | embed | infra/Terraform> ·
**Live configs to republish:** <slug(s) + envs | none> ·
**Breaking contract change:** <yes | no>

### Goal
<2–4 sentences: what is true when this is done, in the user's terms.>

### Resolved clarifications
| Question | Answer |
|---|---|
| <what was ambiguous> | <what we decided, and why> |

### Requirements checklist
| # | Requirement (observable outcome) | Surface |
|---|----------------------------------|---------|
| R1 | <what must be true when done — observable, not an implementation step> | backend/ui/embed/infra/config |

### Approach
<The shape of the solution and the one or two real alternatives considered, with why this one. Name the existing pattern being followed (`file:line`). If a platform capability is added, state why it's GENERAL rather than integration-specific.>

### Steps
1. **<imperative step>** — `IntegrationService/<path>:<line>` — <what changes> · **Verifies:** R1, R2 · **Test:** `test('<name>')`
2. …
<Each step is a commit-sized chunk (sl-issue commits + pushes per step). Order so nothing is broken between steps.>

### Data / migration
<Flyway `V<n>__…sql` — additive only, never edit a shipped script; Hibernate runs `ddl-auto: validate` so entity + schema must agree. State how the currently-running code keeps working after the migration lands (deploys are not atomic across envs). Or "none".>

### Ops / rollout
<The order of operations after merge: deploy backend (QA first, then PROD) → apply/republish live integration configs → verify. Name each config slug + env. Remember QA = us-west-2, PROD = us-east-1, and that config PATCH is RFC 7386 merge (nested objects merge; explicit null clears). Or "none — merges and rides the next deploy".>

### Tests
<Each testable requirement → its named test and its level (unit / integration / AT, and which spec), per `_shared/testing-policy.md`. R3 → test('biz-reply events are filtered before delivery'). Where an AT doesn't fit, state the reason here. Say how each new AT gets run, since `./gradlew check` doesn't run it. The plan-review gate sends back a plan that skips AT coverage without a reason.>

### Risks & unknowns
- <what could go wrong, blast radius, and the mitigation>

### Out of scope
- <explicitly not doing, so nobody assumes it>

### Plan review
<Verdict from step 5: the panel's blockers folded in, plus any concern consciously accepted with a one-line reason. Name which models reviewed.>

---
> **For a future `/sl-issue` (or any agent picking this up):** this is the **plan of record** for
> this ticket — the clarifications above are settled; don't re-ask them. Start from the requirements
> checklist and the steps. Re-plan only if the ticket's scope changed after <YYYY-MM-DD>, or if
> grounding shows the referenced code has moved — and say so if you do.
```

**Searchlight rigor checks — work these into the plan before it goes to review.** These are the failure modes this codebase actually hits:
- **IAM before S3.** Any new bucket/prefix/action (Put, Delete, ListBucketVersions…) needs the Terraform task-role policy widened in the same change, or it AccessDenies in the deployed env only.
- **Metrics are unverifiable in deployed envs.** There is no Micrometer exporter and actuator exposes only health/info, so an acceptance criterion of the form "emits counter X" **cannot be validated in QA/PROD**. Plan a log line or an API-observable signal instead, or state the caveat explicitly in the plan.
- **Capability ≠ live.** Shipping a capability does not apply it — the corresponding integration configs must be **republished** carrying the new setting. (This is how #141 shipped a filter that wasn't actually in effect.) That's why `**Live configs to republish:**` is in the header.
- **Deploy is two envs, two regions.** QA = us-west-2, PROD = us-east-1, both under `AWS_PROFILE=searchlight` (account 911229172008). A plan that says "deploy" must say which envs and in what order.
- **Fail-open vs fail-closed** is a real decision for filters, hydration and drift checks — a throwing predicate can silently tear down subscriptions. State which one, and why.
- **No `.github/workflows`.** "CI green" means `./gradlew check` run locally and recorded on the PR — don't plan a CI job.

### 5. Plan-review gate  ← before it lands on the card
A plan nobody checked is worth less than no plan, because it gets trusted. Run it through `_shared/review-gate.md` — the roster (1× `sl-depth-reviewer` + 1–2× `sl-panel-reviewer`, escalated on its triggers), adjudication, the one delta round and the hand-off to you all live there. This step owns only the lenses and where the verdict lands:

- **Lenses** — the `sl-depth-reviewer` asks *will this plan satisfy every checklist row, and what breaks?*; each `sl-panel-reviewer` takes one of: edge cases, missed states & a simpler alternative; integration-contract & live-data blast radius; or ops/deploy/migration ordering.
- **Verdict** — confirmed BLOCKERs are folded into the plan; the CONCERN ledger and the reviewing models go in the plan's `### Plan review` section.

> **Review gate:** roster → dispatch → adjudicate → one delta round → ask, per `_shared/review-gate.md`.

### 6. Persist it on the card  ← the deliverable  (skipped entirely on `--dry-run`)
Print the finished plan to the terminal first, then confirm the write with **one** `AskUserQuestion` — this is a human's ticket, so nothing lands unconfirmed:

- **Post as a comment** *(recommended, default)* — the plan lands as a comment; the original description stays untouched.
- **Append to the description** — add the plan as a `## 🧭 Implementation plan — sl-plan <date>` section at the **end** of the body, preserving everything above it.
- **Both**
- **Neither (terminal only)** — you want to iterate on it more first.

```bash
# comment (default) — write the rendered plan to a file so markdown survives verbatim
gh issue comment <n> --repo Zangow/IntegrationService \
  --body-file "${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-plan/PLAN-<n>.md"

# description (if chosen) — append, never overwrite
gh issue view <n> --repo Zangow/IntegrationService --json body --jq .body > /tmp/body.md
{ cat /tmp/body.md; echo; cat "${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-plan/PLAN-<n>.md"; } > /tmp/body.new.md
gh issue edit <n> --repo Zangow/IntegrationService --body-file /tmp/body.new.md
```
**Revising an existing plan** (step 1 found one, no `--replan`): post the new plan with a `> Revises the plan in <comment-url> — <one line on what changed and why>` line under the heading, so the ticket's planning history stays readable. Never silently delete or overwrite a prior plan comment.

If a write fails (usually gh auth/permissions), surface it and hand the user the local plan path — the plan itself isn't lost.

## Output
Report: the issue title + URL + current board column, the **plan** (or a pointer to it), the **clarifications you resolved with the user**, the **change-type verdict** (config-only vs platform capability) and the **deploy/republish footprint**, the **plan-review outcome** — blockers folded in, concerns accepted, and which models reviewed — where the plan landed (comment / description / both / terminal-only, or `--dry-run`), and the local paths to `PLAN-<n>.md` and `REQUIREMENTS-<n>.md`. Close with the obvious next step: `/sl-issue <n>` to build it.

## Guardrails & notes
- **Planning only.** No feature code, no branch, no worktree, no env boot, no PR. The only writes are the user-gated issue comment / body edit in step 6.
- **Clarifying is the feature, not the exception.** Unlike `sl-issue`, stopping to ask is what this skill is *for*. Ask in batches, with concrete options, and only about things that change what gets built or materially change the plan.
- **Ground before you plan.** Every step should name a real `file:line` from the step-2 grounding. A plan of generalities is the failure mode this skill exists to prevent.
- **The comment is the durable plan; the local file is a working copy.** Keep the checklist and clarifications inline in the comment — a later `/sl-issue` may run on a different machine, or in a worktree where `.sl-plan/` isn't visible.
- **Never move the card, never assign it.** Planning doesn't change work state; `sl-issue` owns the board moves.
- **Preserve ticket history.** Append to bodies, revise plans by posting a linked revision, and never overwrite a human's text.
- **Canonical-schema changes need sign-off first.** If the plan would change a published standard schema (the `#5`/`#56`/`#30` class of change), flag it and get the owner + ingestion-owner to sign off **before** the plan is treated as actionable — say so in `### Risks & unknowns`.
- **All Searchlight cards live in `Zangow/IntegrationService`.** Skills themselves live in `Zangow/SearchlightClaude` (`$SL_BASE_PATH/.claude/`) — a plan that changes a skill still gets its card here.

## Related
- `sl-issue` — implements + ships a ticket. Reads an `sl-plan` comment as the plan of record instead of re-planning (its step 1), so `/sl-plan` → `/sl-issue` is the intended pairing.
- `sl-create-integration` — for "onboard platform X" cards, which are config-authoring runs rather than code changes. Plan a *capability gap* here; hand the config authoring to that skill.
- `sl-ship` — the quality → verify → PR pipeline `sl-issue` hands the finished code to.
- `sl-deploy` — the rollout the plan's `### Ops / rollout` section is describing.
