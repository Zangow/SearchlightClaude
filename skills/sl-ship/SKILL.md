---
name: sl-ship
description: "End-to-end \"close the loop\" orchestrator for a Searchlight IntegrationService change — runs one review pass (code-review --fix), independent verification (sl-verify, one repair round), then commits, pushes, and opens a review-ready PR with a Refs #n link when issue-driven. Use when a change is code-complete and you want it taken all the way to a PR, or when asked to \"ship it / close the loop / finish and put up for review\"."
effort: high
---

# sl-ship — code-complete → review-ready PR (Searchlight)

> **Repo paths use `$SL_BASE_PATH`** — resolve it per `_shared/base-path.md`.

The top-level pipeline that takes a finished change through quality, independent verification, and PR creation. Run it once the code does what's intended; it does **not** write the feature.

> **This is the final pre-PR pass — not your inner-loop check.** During active iteration, run the build/tests directly for what you just touched (fast). Reserve this full pipeline for when the change is code-complete and you're ready to open review, not after every edit.

> **Run this in its own thread, not in the authoring context** (why: `sl-issue` step 4). If you were dispatched that way, your brief carries the branch, `SL_BASE_PATH`/`SL_REAL_BASE` exports, issue, and checklist path: **export the base paths first**, then read the diff yourself from the branch. If you find yourself invoked *inline* from a context that just wrote the code, say so and hand off instead.

## Pipeline

### 0. Branch guard — never ship from `main`
Before anything else, confirm the repo is on a feature branch, not `main`. Invoked via `sl-issue` it already is (branch cut up front, incremental commits). Run standalone on a code-complete change that's still sitting on `main`, **move it to a branch first**: `git -C "$SL_BASE_PATH/IntegrationService" fetch origin main && git -C "$SL_BASE_PATH/IntegrationService" switch -c <feat|fix>/<slug> origin/main`, then commit + push the work before the pipeline runs. Commit each remaining uncommitted chunk separately — don't batch into one blob commit.

### 1. The review pass — `code-review --fix`  (the ONE review that fixes)

```
Skill(skill: "code-review", args: "<effort> --fix in $SL_BASE_PATH/IntegrationService")
```

> ⚠️ **Pass the absolute worktree path (`$SL_BASE_PATH/IntegrationService`) in the FIRST call.** `code-review` forks with the *session's* cwd — the main checkout under worktree mode — and never reads `SL_BASE_PATH`; fixing it later via `SendMessage` costs a full re-run. **Sanity-check the scope before accepting it:** zero findings on a diff you know is large means it reviewed a clean `main` — re-dispatch with the path, don't bank it as clean; a reported scope naming files your diff doesn't touch means it adopted a dirty checkout — `TaskStop` it before `--fix` writes (`Zangow/SearchlightClaude#1`).

**Effort — `medium` by default.** Raise to **`high`** when the caller passed `--thorough`, or when the diff hits `sl-verify`'s escalation trigger list ("Model & panel policy") — the one copy of that list. Why `medium`: `_shared/finding-disposition.md` "Effort follows the disposition".

**`--thorough`** is an input to `sl-ship` (and `sl-issue` passes it through): it raises this step to `high` and enables `sl-verify`'s second panelist. Nothing else reads it.

> ⚠️ **It forks to the background.** The Skill call returns immediately with an agent name; the findings arrive later as a task notification. **Wait for that notification before step 2**, in bounded foreground slices per `_shared/waiting.md` — proceeding as if it ran inline means `./gradlew check` and `sl-verify` test a tree that's still being rewritten underneath them. If no notification has arrived after ~15 minutes, or the task reports an error, treat it as a **failed launch** and take the fallback ladder below — don't wait indefinitely and don't proceed as though it passed.

**Commit what it fixed before step 2.** `--fix` writes to the working tree, but `sl-verify`'s runner reads `git diff origin/main...HEAD` — so uncommitted review fixes are invisible to the verifier. Commit them (`review: apply code-review findings`) once the notification lands and `./gradlew check` is green. Green here means what `_shared/testing-policy.md` §3 says: `docker info` first (Docker down is BLOCKED, not FAIL), no `-q`, and `_shared/gradle-test-count.sh` counts quoted, never a bare `BUILD SUCCESSFUL`.

Two things this pass does *not* do, owned elsewhere:
- **"Does it meet the requirement?"** → `sl-verify`'s requirements pass (step 2). Standalone runs: check it yourself.
- **"Is there acceptance coverage?"** → the acceptance-coverage check in step 2.

**Disposition: `_shared/finding-disposition.md`.** Critical and High get fixed **now**. Medium and Low get **dropped** — if `--fix` already applied one and it's clean, leave it, but don't chase it. Run the full `./gradlew check` **once** after the fixes (a `--tests` run doesn't count) and move on — **no review of your own fixes** (`_shared/finding-disposition.md`).

**This is the pipeline's only scheduled correctness review**; the fallback ladder below is the one exception. Once the PR is open, the human who approves the merge in `sl-issues` is the second reader.

#### If the review can't launch — the fallback ladder
`code-review`'s model-invocability sits behind a remote gate, so it can stop being launchable with no local change. **Shipping unreviewed is not an available outcome**, but wedging isn't either. In order:

1. **Retry once — but only after the first task is confirmed dead.** A transient task error is not a gate flip. If the retry is triggered by the ~15-minute bound rather than an explicit error, **stop the first task before retrying** (`TaskStop`): a slow-but-alive review plus a retry is two agents rewriting the same working tree at once, which is the hazard the bound itself warns about. Note that the escalation triggers raise effort on exactly the diffs that review slowest — on a `high`-effort pass over a 500+ line diff, give it ~25 minutes before calling it dead.
2. **Fall back to the built-in in its PR form.** (History: the `code-review:code-review` plugin was uninstalled 2026-08-22 — never invoke it.) Finish step 2, then at step 3 open the PR (`gh pr create`), run `gh pr ready <PR#>` (the reviewer refuses drafts), and call `Skill(skill: "code-review", args: "<effort> <full PR URL>")`. **Pass the full URL, not a bare number** — a bare number is resolved against the cwd repo. This form reads the PR from GitHub, so it cannot land in the wrong checkout; it also does **not** write, so apply any **Critical/High** yourself in the worktree, re-run `./gradlew check` plus the targeted tests, and push. Say in the PR body and the ship report that the review ran in PR form and what triggered it. This is a *substitute* for step 1, not an addition — it does not consume `sl-verify`'s repair round.
3. **Both forms failed → stop.** Report both failures verbatim and ask the user to run `/code-review medium --fix` on the branch themselves. **In the main thread**, wait for their confirmation. **Dispatched as a subagent** (the `sl-issue` step-4 case, where you cannot prompt anyone), return **`SHIP-BLOCKED: review-unavailable`** as your final message with both failures, the branch, and the worktree path — no PR, no merge. Never downgrade a blocked review into a caveat on a PR you opened anyway.

**Never hand-roll a substitute review panel**, and never treat verification as covering for a missing review — `sl-verify` answers *does it behave as required*, not *is this code correct*.

> **Resuming after `SHIP-BLOCKED`.** If your brief states the review was **already run by the user** on this branch (naming the branch and roughly when), **skip this step entirely** — do not invoke `code-review` again; that is what wedges the recovery into a loop. **First check the tree is clean** (`git status --porcelain`): a user-run `--fix` usually leaves its edits uncommitted, and `sl-verify` reads `origin/main...HEAD`, so commit them (`review: apply code-review findings`) before you verify — otherwise step 2 verifies a tree without the fixes and step 3's `git add -A` ships them unverified. Then start at step 2, and record in the ship report that step 1 was satisfied by a user-run review.

### 2. Independent verification — `sl-verify`  (one repair round, capped)
Invoke **`sl-verify`**. It runs the mechanical checks (build, tests, lint) inline, then dispatches **one separate, unbiased agent** to verify real runtime behavior — plus requirements traceability in the same pass when the work came from an issue (pass the checklist path through). On a Critical/High FAIL it takes **one** repair round — fix, re-verify — then reports. Collect its summary + evidence + caveats.

**Do not proceed to PR until verification is green.** Green means no row reads `FAIL` or `BLOCKED`. A row spelled **`PASS (dropped: <sev>)`** *is* green — it is a Medium/Low observation the verifier deliberately didn't repair per `_shared/finding-disposition.md`; carry its Caveats text into the PR body verbatim and proceed. A row spelled `PASS (handoff)` is also green. The loop is capped at **1 code-fix round** (`sl-verify` step 3); environment BLOCKED re-dispatches and inline mechanical re-runs don't count against it. At the cap, stop — don't keep grinding. Report `SHIP-FAILED:` with the verifier findings verbatim, what the round tried, and the branch + worktree left in place. If it's genuinely close, `sl-verify` step 3's one cold-agent handoff is the only way on — never a second round here.

**Acceptance-coverage check — before the PR, not after the deploy.** Per `_shared/testing-policy.md` §1, confirm one of these is true and say which in the PR body:
- the change extends or adds an **AT** and it has **actually been run**, with its count read; or
- the reason an AT doesn't fit is stated.

Neither one true → that's a finding to fix now, not a follow-up. This is what makes `sl-deploy`'s QA gate meaningful: it can only catch a regression the pack actually covers.

### 3. Open the PR
**PR-review variant:** if step 1 fell back to rung 2, open the PR as below and then run rung 2 on it. Otherwise open the PR normally.

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
End your final message with the return contract your brief asked for: the **PR URL**, the `VERIFY SUMMARY` block, the requirements table with each row's ✅/❌ and evidence, the step-1 review outcome (which review ran — built-in on the tree, built-in in PR form (rung 2), or user-run on resume — what it found, and what you fixed), and any caveat or deferred requirement. Disposition every review finding per `_shared/finding-disposition.md` — Critical/High fixed in-run, Medium/Low dropped — and do **not** return a follow-up list. `sl-issue` moves the card to **"In review"** off that report — it owns the board move, and it only makes it if a PR URL came back. If verification never went green, return `SHIP-FAILED:` with the findings instead of a PR URL, so the card correctly stays in "In progress". Run standalone, there's no board interaction here.

## Output
Report: what the review pass found and changed, the verification verdict, and the PR URL — so the user can go straight into review.

## Notes
- **Budget: 1 fixing review + 1 verify repair round + at most 1 handoff** — the table in `_shared/finding-disposition.md`. About to start a third editing pass over the same diff → stop and report instead.
