---
name: sl-issue
description: Front door that turns a Searchlight IntegrationService GitHub issue into a shipped PR — pulls the issue (title, body, comments, labels) via gh, assigns it to the user and moves its card to "In progress" on the Searchlight Integration Service board, extracts a structured requirements checklist, adopts a persisted sl-plan plan of record when the card carries one (verifying it exists and still holds first, and re-planning only what drifted) or plans from scratch when it doesn't, implements the change, then runs the full sl-ship pipeline (quality → independent verify → PR) with a requirements-traceability gate and a Refs #n link so the PR cross-links the issue (without auto-closing it). On completion it moves the card to "In review". Use when asked to "/sl-issue <n> / work this Searchlight issue / pick up IntegrationService issue <n>".
effort: high
---

# sl-issue — GitHub issue → implemented → shipped PR (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (the parent dir of the IntegrationService repo). Repo checkout: `$SL_BASE_PATH/IntegrationService`. If unset, set it first in every shell snippet: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`.

The autonomous front door for issue-driven Searchlight work. Given a GitHub issue, this skill **fetches** the requirements, **plans + implements** the change, then hands the finished code to **`sl-ship`** to take it through quality → independent verification → PR. The one responsibility versus `sl-ship` (which never writes the feature) is the **authoring phase** and the **requirements checklist** that threads through verification and the PR.

You stop for review at the **PR gate** — not before. Implement and ship autonomously; the human reviews the PR.

## Inputs
An issue URL (`https://github.com/Zangow/IntegrationService/issues/<n>`) **or just an issue number** — e.g. `12` or `#12`. A bare number **defaults to the `Zangow/IntegrationService` repo**. If no issue was given at all, ask for it.

**Flags:**
- **Worktree mode is the default** — every run does all the work in an **isolated git worktree** of IntegrationService instead of the main checkout, so a run never touches your primary working copy and **multiple `/sl-issue` sessions can author different issues in parallel** without colliding on files. See "Worktree mode" below.
- `--skip-worktree` — opt **out** of worktree mode and cut the branch directly in the main checkout instead. Use this for a single, focused run when you don't need parallel isolation. Changes the branch/path setup (step 2.5).

## Board contract (Searchlight Integration Service — Zangow user project #1)
Status columns: `Backlog`, `Ready`, `In progress`, `In review`, `Done`.
- **On start**: assign the issue to the user (`@me`) and move the card to **"In progress"**.
- **On completion** (PR is up): move the card to **"In review"**. No end-column question — this is fixed, unlike dw-issue.
- The team moves cards to "Done" and closes issues manually on merge; this skill never does either.

## Pipeline

### 1. Fetch the issue
Pull everything that could carry a requirement — the body *and* the comment thread (real acceptance criteria often live in comments):
```bash
gh issue view <n> --repo Zangow/IntegrationService \
  --json number,title,body,labels,assignees,comments,url,milestone
```
Note any linked issues / `Depends on` / task-list sub-items in the body.

**Mark the card as started** — right after the fetch, before any planning or code:
```bash
MOVE="${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-move-issue-column.sh"
"$MOVE" Zangow/IntegrationService <n> "In progress"
gh issue edit <n> --repo Zangow/IntegrationService --add-assignee @me
```
Both are best-effort: if a board move or assignee add fails (usually missing `read:project`/`project` gh scopes — `gh auth refresh -s read:project,project`), surface it and keep going; board status is a convenience, not a gate on the actual work.

**If the card carries an `sl-plan` plan of record** — a comment headed `## 🧭 Implementation plan — sl-plan <date>` — that plan is the **plan of record**: a human already worked through the clarifications with Claude and signed off on a reviewed plan. Don't re-plan from scratch. **Verify it exists and still holds before trusting it** (in this order — a stale plan followed blindly is worse than no plan):
1. **It exists.** Scan the comment thread for the heading. If several exist, take the **newest** (a later plan may say `> Revises the plan in <url>`). If none exists, there is no plan of record — plan normally in step 3.
2. **It's still accurate.** Spot-check the plan's `file:line` anchors against the current checkout (`git -C "$SL_BASE_PATH/IntegrationService" log --oneline --since="<plan date>" -- <paths>`, and open a couple of the referenced files). Also re-read the issue body/comments for scope changes **after** the plan's date. On this codebase, also re-check the plan's `**Change type:**` and `**Deploy needed:**` header claims — a capability the plan assumed was missing may have shipped in the meantime (or vice versa).
3. **It's complete.** It must carry a requirements checklist and steps. A plan with unresolved open questions in `### Risks & unknowns` that change *what* to build is not signed off — resolve those per step 2's ambiguity rule before implementing.

Then: **accurate + complete →** adopt it. Reuse its requirements checklist verbatim as step 2's artifact (prefer the inline table in the comment; `${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md` may already exist from the `sl-plan` run — use it if present, and if it disagrees with the comment, the **comment wins**), implement its steps in order, and **skip the plan-review gate in step 3** — the plan was already reviewed by a fresh panel. Carry its `### Ops / rollout` section into the PR description so the deploy/republish footprint isn't lost. **Stale or incomplete →** say so explicitly, state what drifted, re-plan the affected parts on top of it (don't discard the resolved clarifications — those stay settled), and run the step-3 plan-review gate on the amended plan. Either way, **report in the final output which plan you followed and whether you amended it**.

### 2. Build the requirements checklist  ← the key artifact
Distill the issue + comments into an explicit, testable checklist. One row per discrete requirement, each phrased as an observable outcome (not an implementation step). Include implicit must-haves the issue implies (auth, validation, empty/error states) and mark anything ambiguous.

Write it to a stable, non-repo path so the fresh verification agents (which don't share your context) can read it, and so it never lands in the repo's history:
```
${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md
```
In worktree mode `SL_BASE_PATH` gets repointed in step 2.5 — writing through `$SL_REAL_BASE` keeps the checklist findable by every downstream skill. Pass the absolute checklist path explicitly when invoking `sl-ship`.

Format:
```markdown
# Requirements — Zangow/IntegrationService#<n>: <title>
Issue: <url>

| # | Requirement (observable outcome) | Status | Evidence |
|---|----------------------------------|--------|----------|
| R1 | <what must be true when done> | ☐ | |
| R2 | … | ☐ | |

## Out of scope / assumptions
- <anything you read as out of scope, or an ambiguity you resolved a particular way>
```

**Handling ambiguity (the one thing autonomy shouldn't guess):** if a requirement is genuinely ambiguous in a way that changes *what to build* (not just how), pause and resolve it before implementing:
1. **Ask the user** the specific clarifying question(s) (use `AskUserQuestion` with concrete options).
2. **Write the clarification back to the GitHub issue** so the ticket becomes the source of truth:
   ```bash
   gh issue comment <n> --repo Zangow/IntegrationService --body "<clarification>"
   ```
3. **Update the local checklist** to reflect the resolved requirement, then proceed.
Only ambiguities that change *what* gets built warrant this; resolve pure implementation choices yourself.

### 2.5 Create the feature branch  ← do this BEFORE writing any code
Never implement on `main`. **Branch name** — derive once from the issue:
```
feat/issue-<n>-<slug>     # enhancement
fix/issue-<n>-<slug>      # bug
```
`<slug>` is a short kebab summary of the issue title (e.g. `feat/issue-12-webhook-retries`).

**Default (worktree mode)** — create an isolated worktree of the repo, then repoint `SL_BASE_PATH` at the worktree root so every downstream skill (`sl-verify`, `sl-ship`) operates on the worktree transparently. The shared helper does the `git worktree add` (off freshly-fetched `origin/main`) + initial push:
```bash
WT="${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-worktree.sh"
ROOT="$("$WT" create issue-<n>-<slug> <branch>)"
export SL_REAL_BASE="$SL_BASE_PATH"   # remember the true base (for checklist paths + cleanup)
export SL_BASE_PATH="$ROOT"           # ← from here on, all repo paths resolve to the worktree
```
The worktree lives at `$SL_REAL_BASE/.sl-worktrees/issue-<n>-<slug>/IntegrationService` on `<branch>`. **Never persist the repointed `SL_BASE_PATH`** to a shell profile — it is session-only.

**With `--skip-worktree`** — cut the branch directly in the main checkout instead (so work is committed and pushable from the first edit, not stranded uncommitted on `main` if interrupted):
```bash
git -C "$SL_BASE_PATH/IntegrationService" fetch origin main
git -C "$SL_BASE_PATH/IntegrationService" switch -c <branch> origin/main
git -C "$SL_BASE_PATH/IntegrationService" push -u origin <branch>   # publish immediately so work has a remote home
```

### 3. Plan + implement  (commit + push incrementally)
**If step 1 adopted an `sl-plan` plan of record, this step is already done** — implement its steps in order and skip straight to the incremental commit loop below (no re-planning, no plan-review gate). Only the parts you had to amend as stale get planned and reviewed here.

Otherwise, plan the change against the checklist **inline, in the main thread** — you have to load the relevant files to implement anyway, so a separate planning agent just pays to read the same context twice. Planning and authoring are **core roles — keep them on the strongest available model**; reserve cheaper models for the review/verify panels downstream.

**Plan-review gate (contract-level changes only; skipped when a reviewed `sl-plan` plan was adopted).** Dispatch a fresh plan reviewer (Agent tool, **`subagent_type: sl-depth-reviewer`** — opus @ high by definition) before writing code **only when** the plan changes a published contract/schema, an external integration contract, or persistence/migrations — the class of change where a wrong plan is expensive to unwind. Hand it the issue, the requirements checklist, and your written plan; ask: will this plan meet every checklist row? what will break? what's simpler? Fold blockers into the plan before implementing. For everything else, skip the gate — plans are cheap to revise mid-implementation, and the verification loop is the real safety net.

**Derive tests from the checklist, not the code.** Turn each testable checklist row into a named test (`R3 → test('…')`) so the requirements pass in `sl-verify` maps rows → tests directly. Post-hoc tests encode what the code *does*, not what the issue *required*.

**Which level of test — default to an acceptance test, and always keep the unit/integration layer too.**
1. **Every new feature and every bug fix should land acceptance-test coverage** of its externally-observable outcome. This is the default expectation, not the exception — if a change ships without an AT, that's a decision you have to justify (see 3), not a silent omission. The reason is deployment: the AT pack is what `sl-deploy` runs against QA, and (on a QA→PROD run) what **gates PROD**. A behavior with no AT is a behavior nobody checks after a deploy.
2. **Prefer extending an existing spec over writing a new one.** Find the test that already exercises that endpoint/flow and add the case or assertion there; a new spec is warranted only when nothing covers the flow, or when folding it in would make one test cover two unrelated things. Search first (`rg -l "<endpoint|flow|slug>" acceptance-tests/src e2e/specs src/integrationTest`), then say which you did and why.
   - **`acceptance-tests/`** (`AcceptanceTestBase` subclasses) — black-box HTTP + S3 against a *running* target: admin API, catalog/authZ, registration → poll/push → delivery, idempotency/residue.
   - **`e2e/specs/*.spec.ts`** (Playwright) — real-browser flows through the admin UI and the customer embed card (the connect → register → deliver → unsubscribe loop). This is the AT layer for **`ui/` and `ui-embed/`** work.
   - **`src/integrationTest/`** (Testcontainers: Postgres + LocalStack, needs Docker) — anything crossing persistence/S3/Secrets that isn't observable from outside.
3. **When an AT genuinely doesn't fit, use unit/integration instead — and record why.** Legitimate cases: a pure helper or formatter, an internal branch no API or UI surface can reach, a condition the pack can't provoke without absurd fixture gymnastics, or a signal that isn't observable in a deployed env at all (**Micrometer counters — there is no exporter**; plan a log line or an API-observable signal instead). Note the reason in the checklist and in the PR body so a reviewer sees it was a call, not an oversight.
4. **Unit/integration tests are still required even when you add an AT.** These are not alternatives. The AT proves the outcome end-to-end; the unit/integration layer pins the logic, edge cases, and error paths at the level where a failure actually tells you what broke. Adding an AT never excuses skipping them.
5. **Know what the PR gate does and doesn't run.** `:acceptance-tests:acceptanceTest` is deliberately **outside `./gradlew check`** — it needs a running target — so a new AT is *not* exercised by the pre-PR build. Run it yourself against a local stack (`scripts/run-acceptance.sh local` after `sl-start-env`) so you're not handing over a spec that has never executed; `sl-verify` expects that evidence, and `sl-deploy` runs the same pack against QA post-deploy.

Record the chosen level per requirement in the checklist's Evidence column (e.g. `AT: RegistrationPollDeliveryAcceptanceTest (extended, run vs local)` + `unit: RecordFilterTest`) so the requirements pass in `sl-verify` can check both layers.

Keep the checklist open as your definition of done — every `☐` must be addressed by code (or explicitly moved to out-of-scope with a reason).

**Commit + push after each completed step** (a checklist row or a coherent chunk) — don't batch everything into one commit at the end:
```bash
git -C "$SL_BASE_PATH/IntegrationService" add -A
git -C "$SL_BASE_PATH/IntegrationService" commit -m "<imperative subject>" -m "<short body: what + why, Refs #<n>>"
git -C "$SL_BASE_PATH/IntegrationService" push
```
Imperative subject scoped to the step, a one-line body, and a `Refs #<n>` trailer. End the commit body with the Co-Authored-By trailer the harness instructions specify for the current model.

### 4. Ship it — hand off to `sl-ship` in a FRESH agent  ← never run the pipeline in this context

**Authoring ends here.** Your context now holds the issue + comments, every file you read while planning, the whole implementation diff, and every commit message. Invoking `sl-ship` inline stacks `/code-review`, the verification loop, the repair rounds and the PR write-up *on top of that* — and because the full context is re-read on every tool call, the pipeline costs several times more here than it does in a fresh thread. Measured runs peaked at 400–560K context and spent ~90% of their tokens re-reading their own history; the driver agent alone was two-thirds of the cost of an entire issue.

So **dispatch `sl-ship` as a separate agent** — Agent tool, **`subagent_type: sl-core-worker`** (opus @ high by definition; `sl-ship` repairs code, which is authoring), `run_in_background: false` (you need its verdict before step 6). Nothing is lost by starting it cold: the work is **committed and pushed** (step 3), and the checklist lives **outside the repo**, so every input it needs is on disk rather than in your head.

**The handoff brief must carry all of this** — a ship agent that has to ask you for context defeats the purpose:

1. **The invocation** — "Invoke the `sl-ship` skill (Skill tool, `skill: sl-ship`) and follow it end to end."
2. **Environment** — ⚠️ env vars do **not** cross an agent boundary. Spell out the exports verbatim, or a worktree run silently ships from the main checkout:
   ```bash
   export SL_REAL_BASE="<the true base, e.g. /Users/danieljohnston/git/Searchlight>"
   export SL_BASE_PATH="<$ROOT from step 2.5, or the same as SL_REAL_BASE with --skip-worktree>"
   ```
3. **The change** — the branch name and the base it was cut from (`origin/main` as of step 2.5). Tell it to read the diff itself (`git -C "$SL_BASE_PATH/IntegrationService" diff origin/main...HEAD`) rather than pasting the diff into the prompt.
4. **The issue** — `Zangow/IntegrationService#<n>` + URL, and the **absolute path to the requirements checklist** (`${SL_REAL_BASE}/.sl-issue/REQUIREMENTS-<n>.md`).
5. **What you already know** — anything a cold reader can't recover from the diff: requirements you moved out of scope and why, an ambiguity you resolved with the user, an `sl-plan` plan you amended (including its `### Ops / rollout` section, which must reach the PR body), the test levels you landed per row, and whether each new AT was actually **run** against a live target. Keep this to a short list of facts, **not** your authoring reasoning — the point of a fresh context is that it reads the code without your rationalizations.
6. **Its authority** — "Run the review; if the built-in `code-review` cannot launch, take your documented plugin fallback, and only if **both** fail stop and return `SHIP-BLOCKED: review-unavailable` — never ship unreviewed. Otherwise you own the repair loop: if verification FAILs, fix the code, commit, push, and re-verify **within `sl-verify`'s **1-round** cap**, and only for a Critical/High FAIL — anything Medium/Low is dropped per `_shared/finding-disposition.md`, not repaired. If it is still not green at the cap, stop and return `SHIP-FAILED:` with the verifier findings verbatim — do not keep looping."
7. **The return contract** — "End your final message with: the PR URL; the `VERIFY SUMMARY` block; the requirements table with each row's ✅/❌ and evidence; the review outcome (what `code-review` found and what you fixed); and any caveat or deferred requirement. Disposition every review finding per `_shared/finding-disposition.md` — Critical/High fixed in-run, Medium/Low dropped. Do **not** return a follow-up list."

sl-ship then runs its normal pipeline — one `code-review --fix` pass (`medium` by default; `high` on `--thorough`, on an auth/secrets/persistence/contract diff, or over ~500 changed lines) → `sl-verify` (one repair round, including the requirements-traceability pass) → PR. There is **no routine post-PR review step**: once the PR is open the pipeline stops editing code. And:
- **`sl-verify`** maps each checklist row → real evidence (code/test/endpoint response/screenshot) and marks it ✅/❌. Any unmet requirement is a FAIL the ship agent repairs, subject to the same 1-round cap.
- The PR embeds the satisfied-requirements table and adds the **`Refs`** link (step 5).

**If it returns `SHIP-FAILED:`** — do **not** re-dispatch a second ship agent and do not start fixing in this context (that reintroduces exactly the cost this step removes). Report the failure with the findings, leave the branch and worktree in place, and **do not move the card to "In review"** (step 6 is contingent on a PR existing). When invoked under `sl-issues`, that report is what the driver reads.

**If it returns `SHIP-BLOCKED: review-unavailable`** — **both** reviewers failed to launch, so the change is code-complete but **unreviewed**. Do not open the PR yourself, and do not treat `sl-verify` as a substitute (it answers *does it behave as required*, not *is this code correct*). Do **not** re-dispatch the ship agent as-is — it would restart at step 1, hit the same failure, and return the same sentinel forever. Instead: **surface it to the user and stop** — report both failures verbatim, the branch, and the worktree path, and ask them to run `/code-review medium --fix` on the branch themselves. Once they confirm it's done, re-dispatch the ship agent with one extra line in the brief — **"The review for step 1 has already been run by the user on `<branch>` (`code-review medium --fix`, <when>). Skip step 1 and start at step 2."** — which is the input `sl-ship` step 1's resume clause is written to accept. The card stays in "In progress" until then.

### 5. Link the issue — without auto-closing  (handled inside sl-ship's PR step)
The PR must **reference** the issue but must **not** auto-close it on merge — issues are closed manually. Use a plain, non-closing reference:
```
Refs #<n>
```
**Do NOT use `Closes` / `Fixes` / `Resolves`** — those keywords trigger auto-close.

### 6. Move the card to "In review"  ← once the PR is up
```bash
MOVE="${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-move-issue-column.sh"
"$MOVE" Zangow/IntegrationService <n> "In review"
```
Only move after `sl-ship` has actually opened the PR — a card shouldn't leave "In progress" while the work is still verifying or looping back to step 3. If the board update fails, surface it but don't treat it as a failure of the change itself.

## Worktree mode (the default; opt out with `--skip-worktree`) — lifecycle summary
- **Setup** (step 2.5): `sl-worktree.sh create` makes a worktree of IntegrationService under `$SL_REAL_BASE/.sl-worktrees/issue-<n>-<slug>/`, then the session repoints `SL_BASE_PATH` at that root. Everything downstream uses the worktree with no other changes.
- **Author in parallel**: edit/commit/push are isolated — a second `/sl-issue` session can author a different issue at the same time without file collisions.
- **Verification**: if verification needs a shared singleton resource (bound ports, a shared dev DB), serialize through the env mutex — `"$WT" env-claim --wait` before booting, `"$WT" env-release` after. While the service has no such singleton, verify freely in parallel.
- **Cleanup** (after the PR is up): remove the worktree. The branch lives on the remote, so removing the worktree loses nothing:
  ```bash
  "$WT" remove issue-<n>-<slug>          # add --force only if you mean to discard uncommitted work
  ```
  Offer this to the user once the PR is open; don't remove a worktree with uncommitted changes without confirming.

## Output
Report: the issue title + URL, **whether an `sl-plan` plan of record was adopted** (and if so, whether you followed it as-written or amended stale parts — naming what drifted), the requirements checklist with each row's final ✅/❌ and evidence, the verification verdict, the PR URL with its `Refs` link, and confirmation the card moved to **"In review"**. Surface any requirement you moved out of scope up front, and remind the user the issue is **linked but not auto-closed** — they close it on merge. In worktree mode (the default), also report the worktree root path and whether you removed it or left it on disk.

## Notes
- **Autonomy boundary**: implement and ship without stopping; the only allowed pause is **up front, before implementation** — a requirement that's ambiguous in a way that changes *what* gets built. Record the answer back on the GitHub issue so the ticket stays the source of truth. After that, run straight through; the PR is the review gate. (If the ambiguities are the *point* of the exercise, that's `/sl-plan`, not this skill.)
- **An `sl-plan` plan of record is trusted, not obeyed.** Adopt it only after the step-1 existence + staleness + completeness check passes; if the code moved or the scope changed since it was written, say what drifted and amend it rather than implementing a plan against a codebase that no longer matches. Its *resolved clarifications* stay settled either way — those were a human decision, not a guess.
- **Board status is a convenience, not a gate**: "In progress" / "In review" moves never block the actual change.
- The checklist is the contract. An unaddressed row is a FAIL, not a caveat.
- **Tests: AT by default, extend before adding, unit/integration always.** A feature or fix without acceptance coverage needs a stated reason (step 3); so does a new spec where an existing one could have been extended. An AT is never a substitute for the unit/integration layer — and since `acceptanceTest` sits outside `./gradlew check`, a new AT you never actually ran isn't coverage, it's a guess.
- **The ship handoff is not optional.** `sl-ship` runs in its own fresh agent (step 4), never inline. Authoring context is the most expensive thing in this pipeline and the ship pipeline is the longest part of it — running them in one thread is what turns a $40 issue into a $150 one. If the ship agent comes back `SHIP-FAILED:`, report it and leave the card in "In progress"; don't retry it here.
- Each downstream step is still runnable on its own; `sl-issue` just adds fetch + author in front of `sl-ship`.
