---
name: sl-ship
description: End-to-end "close the loop" orchestrator for a Searchlight IntegrationService change — runs one review pass (code-review --fix), independent verification (sl-verify, one repair round), then commits, pushes, and opens a review-ready PR with a Refs #n link when issue-driven. Use when a change is code-complete and you want it taken all the way to a PR, or when asked to "ship it / close the loop / finish and put up for review".
effort: high
---

# sl-ship — code-complete → review-ready PR (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. In worktree mode (`sl-issue` default) `SL_BASE_PATH` is already repointed at the worktree root — everything here works unchanged.

The top-level pipeline that takes a finished change through quality, independent verification, and PR creation. Run it once the code does what's intended; it does **not** write the feature.

> **This is the final pre-PR pass — not your inner-loop check.** During active iteration, run the build/tests directly for what you just touched (fast). Reserve this full pipeline for when the change is code-complete and you're ready to open review, not after every edit.

> **Run this in its own thread, not in the authoring context.** `sl-issue` dispatches this skill as a fresh agent (its step 4) precisely so the pipeline doesn't inherit the author's context — a long context is re-read on every tool call, so the same pipeline costs several times more downstream of authoring than it does cold. If you were dispatched that way, your brief carries the branch, `SL_BASE_PATH`/`SL_REAL_BASE` exports, issue, and checklist path: **export the base paths first**, then read the diff yourself from the branch. If you find yourself invoked *inline* from a context that just wrote the code, say so and hand off instead.

## Pipeline

### 0. Branch guard — never ship from `main`
Before anything else, confirm the repo is on a feature branch, not `main`. Invoked via `sl-issue` it already is (branch cut up front, incremental commits). Run standalone on a code-complete change that's still sitting on `main`, **move it to a branch first**: `git -C "$SL_BASE_PATH/IntegrationService" fetch origin main && git -C "$SL_BASE_PATH/IntegrationService" switch -c <feat|fix>/<slug> origin/main`, then commit + push the work before the pipeline runs. Commit each remaining uncommitted chunk separately — don't batch into one blob commit.

### 1. The review pass — `code-review --fix`  (the ONE review that fixes)

```
Skill(skill: "code-review", args: "<effort> --fix")
```

**Effort — `medium` by default.** Raise to **`high`** when the caller passed `--thorough`, or when the diff touches **auth/permissions, credentials/secrets, persistence/migrations, an external integration contract, or a published API/schema contract**, or when it exceeds **~500 changed lines**. (`git diff --shortstat origin/main...HEAD` decides the size trigger; this list is kept identical to `sl-verify`'s model-escalation list — a diff that escalates the verifier must escalate the review.) Rationale for the default lives in `_shared/finding-disposition.md`; the short version is that `high` widens coverage into the Medium/Low band this pipeline drops, and `--fix` has no severity filter, so that band lands in the diff before you can drop it.

**`--thorough`** is an input to `sl-ship` (and `sl-issue` passes it through): it raises this step to `high` and enables `sl-verify`'s second panelist. Nothing else reads it.

> ⚠️ **It forks to the background.** The Skill call returns immediately with an agent name; the findings arrive later as a task notification. **Wait for that notification before step 2** — proceeding as if it ran inline means `./gradlew check` and `sl-verify` test a tree that's still being rewritten underneath them. If no notification has arrived after ~15 minutes, or the task reports an error, treat it as a **failed launch** and take the fallback ladder below — don't wait indefinitely and don't proceed as though it passed.

**Commit what it fixed before step 2.** `--fix` writes to the working tree, but `sl-verify`'s runner reads `git diff origin/main...HEAD` — so uncommitted review fixes are invisible to the verifier. Commit them (`review: apply code-review findings`) once the notification lands and `./gradlew check` is green.

Two things this pass does *not* do, owned elsewhere:
- **"Does it meet the requirement?"** → `sl-verify`'s requirements pass (step 2). Standalone runs: check it yourself.
- **"Is there acceptance coverage?"** → the acceptance-coverage check in step 2.

**Disposition: `_shared/finding-disposition.md`.** Critical and High get fixed **now**. Medium and Low get **dropped** — if `--fix` already applied one and it's clean, leave it, but don't chase it. Run `./gradlew check` **once** after the fixes and move on: **do not re-review your own fixes.** A second pass over a diff the first just rewrote reliably finds new Medium/Low to rewrite again.

**This is the pipeline's only scheduled correctness review.** The step-3.5 plugin pass was removed because it re-reviewed a diff this step had already swept. The one exception is the fallback ladder below. Once the PR is open, the human who approves the merge in `sl-issues` is the second reader.

#### If the review can't launch — the fallback ladder
`code-review`'s model-invocability sits behind a remote gate, so it can stop being launchable with no local change. **Shipping unreviewed is not an available outcome**, but wedging isn't either. In order:

1. **Retry once — but only after the first task is confirmed dead.** A transient task error is not a gate flip. If the retry is triggered by the ~15-minute bound rather than an explicit error, **stop the first task before retrying** (`TaskStop`): a slow-but-alive review plus a retry is two agents rewriting the same working tree at once, which is the hazard the bound itself warns about. Note that the escalation triggers raise effort on exactly the diffs that review slowest — on a `high`-effort pass over a 500+ line diff, give it ~25 minutes before calling it dead.
2. **Fall back to the plugin.** `code-review:code-review` is a locally-installed plugin and is **not** behind that gate — but it reviews a **PR by number**, so it needs a target. Finish step 2, then at step 3 open the PR as a **draft** (`gh pr create --draft`), run `Skill(skill: "code-review:code-review", args: "<PR#>")`, fix any **Critical/High** it posts, re-run `./gradlew check` plus the targeted tests, push, and `gh pr ready <PR#>`. Say in the ship report that the review ran via the plugin fallback and what triggered it. This is a *substitute* for step 1, not an addition — it does not consume `sl-verify`'s repair round.
3. **Both failed → stop.** Report the two failures verbatim and ask the user to run `/code-review medium --fix` on the branch themselves. **In the main thread**, wait for their confirmation. **Dispatched as a subagent** (the `sl-issue` step-4 case, where you cannot prompt anyone), return **`SHIP-BLOCKED: review-unavailable`** as your final message with both failures, the branch, and the worktree path — no PR, no merge. Never downgrade a blocked review into a caveat on a PR you opened anyway.

**Never hand-roll a substitute review panel**, and never treat verification as covering for a missing review — `sl-verify` answers *does it behave as required*, not *is this code correct*.

> **Resuming after `SHIP-BLOCKED`.** If your brief states the review was **already run by the user** on this branch (naming the branch and roughly when), **skip this step entirely** — do not invoke `code-review` again; that is what wedges the recovery into a loop. **First check the tree is clean** (`git status --porcelain`): a user-run `--fix` usually leaves its edits uncommitted, and `sl-verify` reads `origin/main...HEAD`, so commit them (`review: apply code-review findings`) before you verify — otherwise step 2 verifies a tree without the fixes and step 3's `git add -A` ships them unverified. Then start at step 2, and record in the ship report that step 1 was satisfied by a user-run review.

### 2. Independent verification — `sl-verify`  (one repair round, capped)
Invoke **`sl-verify`**. It runs the mechanical checks (build, tests, lint) inline, then dispatches **one separate, unbiased agent** to verify real runtime behavior — plus requirements traceability in the same pass when the work came from an issue (pass the checklist path through). On a Critical/High FAIL it takes **one** repair round — fix, re-verify — then reports. Collect its summary + evidence + caveats.

**Do not proceed to PR until verification is green.** Green means no row reads `FAIL` or `BLOCKED`. A row spelled **`PASS (dropped: <sev>)`** *is* green — it is a Medium/Low observation the verifier deliberately didn't repair per `_shared/finding-disposition.md`; carry its Caveats text into the PR body verbatim and proceed. A row spelled `PASS (handoff)` is also green. The loop is capped at **1 code-fix round** (`sl-verify` step 3); environment BLOCKED re-dispatches and inline mechanical re-runs don't count against it. At the cap, stop — don't keep grinding. Report `SHIP-FAILED:` with the verifier findings verbatim, what the round tried, and the branch + worktree left in place. Round 2 in *this* context costs more than round 1 and is the least likely to work: a failed repair round usually means the **diagnosis** is wrong, and the same context repeats the same wrong model of the bug. If it's genuinely close, hand it to a fresh agent (`sl-verify` step 3) rather than grinding here.

**Acceptance-coverage check — before the PR, not after the deploy.** The standing policy (`sl-issue` step 3) is acceptance coverage by default for every feature and bug fix, with unit/integration retained underneath it. So before opening the PR, confirm one of these is true and say which:
- the change extends or adds an **AT** — `acceptance-tests/` for API/delivery behavior, `e2e/specs/*.spec.ts` for admin-UI/embed behavior — **and it has actually been run** (`scripts/run-acceptance.sh local`, or `scripts/run-e2e.sh qa`); or
- there's a **stated reason** an AT doesn't fit (pure helper, unreachable branch, not observable in a deployed env — e.g. a Micrometer counter, which has no exporter).

Neither one true → that's a finding to fix now, not a follow-up. `:acceptance-tests:acceptanceTest` is **outside `./gradlew check`**, so a green build says nothing about whether a new AT even compiles against a live target — an unrun AT is not evidence. This is what makes `sl-deploy`'s QA gate meaningful: it can only catch a regression the pack actually covers.

### 3. Open the PR
**Draft-PR variant:** if step 1 fell back to the plugin reviewer, add `--draft` to `gh pr create`, run `Skill(skill: "code-review:code-review", args: "<PR#>")`, fix any Critical/High, re-run `./gradlew check`, push, then `gh pr ready <PR#>` — and say so in the PR body and the ship report. Otherwise open the PR normally.

Revert any temporary verification edits first, then commit + push whatever remains (no need to ask):
```bash
git -C "$SL_BASE_PATH/IntegrationService" add -A
git -C "$SL_BASE_PATH/IntegrationService" commit -m "<imperative subject>" -m "<body, Refs #<n> when issue-driven>"
git -C "$SL_BASE_PATH/IntegrationService" push
gh pr create --repo Zangow/IntegrationService --base main --head <branch> \
  --title "<imperative title>" --body-file <body.md>
```
PR body structure (write it to a scratchpad file, then `--body-file`):
- **Summary** — what changed and why.
- **Changes** — bullet list by area.
- **Requirements** — when issue-driven, the satisfied-requirements table from the checklist (each row ✅ with its evidence).
- **How verified** — the `VERIFY SUMMARY` block from `sl-verify`, with screenshots/output embedded or linked. Name the **test levels** the change landed (AT + unit/integration, or the stated reason an AT doesn't fit) — a reviewer shouldn't have to diff the test tree to find out whether this is covered post-deploy.
- **Caveats** — a limitation of the change itself a reviewer or operator must know about, a deliberate scope boundary, an irreversible step already taken. **Not** a follow-ups list: per `_shared/finding-disposition.md` review findings are either fixed before the PR (Critical/High) or dropped (Medium/Low), so neither belongs here. If a line reads like "we should also…", delete it.
- **`Refs #<n>`** when the work came from an issue — a plain, non-closing reference so the PR and issue cross-link. **Never `Closes`/`Fixes`/`Resolves`** — issues are closed manually on merge.
- End with the generated-with footer the harness instructions specify.

Screenshots for anything user-visible: upload via `gh` (gist or release asset — kept out of repo history) and embed inline.

### 4. Hand back to `sl-issue` (when issue-driven)
End your final message with the return contract your brief asked for: the **PR URL**, the `VERIFY SUMMARY` block, the requirements table with each row's ✅/❌ and evidence, the step-1 review outcome (which reviewer ran — built-in, plugin fallback, or user-run on resume — what it found, and what you fixed), and any caveat or deferred requirement. Disposition every review finding per `_shared/finding-disposition.md` — Critical/High fixed in-run, Medium/Low dropped — and do **not** return a follow-up list. `sl-issue` moves the card to **"In review"** off that report — it owns the board move, and it only makes it if a PR URL came back. If verification never went green, return `SHIP-FAILED:` with the findings instead of a PR URL, so the card correctly stays in "In progress". Run standalone, there's no board interaction here.

## Output
Report: what the review pass found and changed, the verification verdict, and the PR URL — so the user can go straight into review.

## Notes
- **Independence where judgment lives**: behavioral and requirements verification is always done by an agent that didn't author the code (enforced by `sl-verify`) — don't shortcut that by judging behavior inline. Mechanical checks (build/tests/lint) run inline by design; an exit code carries no authoring bias.
- Commit + push each change without asking; the PR is the human review gate.
- Each sub-step is also runnable on its own (`sl-verify`, the PR step) when you don't need the whole pipeline.
- **One review that fixes, one round that repairs.** Step 1 (`code-review --fix` on the tree, `medium` unless a trigger raises it) is *the* review pass and *the* fix round; `sl-verify` gets **one** code-fix round on top of it, plus at most **one** handoff. There is no routine post-PR review step — once the PR is open, this pipeline is done editing code. The one exception is step 1's plugin fallback (`_shared/finding-disposition.md`). Nothing else in it is allowed to start a new code edit. Findings are dispositioned by `_shared/finding-disposition.md`: **Critical/High fixed in-run, Medium/Low dropped.** A card ends when its acceptance criteria are met and nothing Critical/High is outstanding — not when every observation has a ticket.
- **Total review budget for a run: 1 fixing review + 1 verify repair round.** If you find yourself about to start a third editing pass over the same diff, stop and report instead — that is the failure mode this pipeline is shaped to prevent.
