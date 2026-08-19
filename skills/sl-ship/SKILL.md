---
name: sl-ship
description: End-to-end "close the loop" orchestrator for a Searchlight IntegrationService change — runs a self-review pass (/code-review --fix), independent verification (sl-verify, looping until green), then commits, pushes, and opens a review-ready PR with a Refs #n link when issue-driven. Use when a change is code-complete and you want it taken all the way to a PR, or when asked to "ship it / close the loop / finish and put up for review".
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

### 0.5 Reviewer preflight — fail loudly now, not at step 3.5
The correctness reviewer (step 3.5) is a **plugin**, so it can be absent. Check that up front: discovering it's missing after `sl-verify` has run means the whole pipeline is already paid for. One cheap check:

```bash
jq -e '.enabledPlugins["code-review@claude-plugins-official"] == true' ~/.claude/settings.json >/dev/null 2>&1 \
  && echo "enabled-in-config" || echo "NOT-enabled"
```

Combine that with whether `code-review` appears in your available-skills listing — config and session-load state are **different things**, and the gap between them is the usual failure:

| Config | In skills listing | State | Say this up front |
|---|---|---|---|
| enabled | yes | ✅ ready | nothing — proceed |
| enabled | no | ⚠ needs restart | "`code-review` is enabled but wasn't loaded this session — restart to activate it, or step 3.5 will be skipped with that as the stated reason." |
| not enabled | no | ⚠ not installed | "`code-review` isn't installed. Add `\"enabledPlugins\": {\"code-review@claude-plugins-official\": true}` to `~/.claude/settings.json` and restart — want me to write it now so the next run has it?" |

**Do not block on this.** The review is mandatory-above-threshold but explicitly skippable *with a stated reason*, and a missing plugin is exactly such a reason — stalling a green pipeline over a config gap is worse than shipping with the gap flagged. Report the state, offer the fix, and carry on. Writing the setting mid-run does **not** make the plugin available to the current session (it loads at startup), so offer it as a fix for the *next* run.

### 1. Self-review pass — `/code-review --fix`  (one pass, replaces `simplify`)
Invoke the **built-in `code-review` skill** on the working tree, at `high` effort, with `--fix`:

```
Skill(skill: "code-review", args: "high --fix")
```

One pass covering correctness bugs **and** reuse / simplification / efficiency cleanups, with `--fix` **applying them to the working tree** instead of leaving them in a report for someone to shepherd. `simplify` is gone — don't invoke it, and don't hand-roll a replacement panel.

> ⚠️ **It forks to the background.** The Skill call returns immediately with an agent name; the findings arrive later as a task notification. **Wait for that notification before step 2** — proceeding as if it ran inline means `./gradlew check` and `sl-verify` test a tree that's still being rewritten underneath them.

Two things this pass does *not* do, now explicitly owned elsewhere:
- **"Does it meet the requirement?"** → `sl-verify`'s requirements-traceability pass in step 2 (issue-driven runs). Standalone runs: check it yourself against the prompt before proceeding.
- **"Is there acceptance coverage?"** → the acceptance-coverage check in step 2.

**Disposition of what it finds: `_shared/finding-disposition.md`.** Critical and High get fixed **now**, in this run, before the PR. Medium and Low get **dropped** — not filed, not carried into a follow-ups list. Re-run `./gradlew check` after any fix.

### 2. Independent verification — `sl-verify`  (loop until green, capped)
Invoke **`sl-verify`**. It runs the mechanical checks (build, tests, lint) inline, then dispatches **one separate, unbiased agent** to verify real runtime behavior — plus requirements traceability in the same pass when the work came from an issue (pass the checklist path through). It loops — fix, re-verify — until everything is PASS. Collect its summary + evidence + caveats.

**Do not proceed to PR until verification is green.** The loop is capped at **2 code-fix rounds** (`sl-verify` step 3); environment BLOCKED re-dispatches and inline mechanical re-runs don't count against it. At the cap, stop — don't keep grinding. Report `SHIP-FAILED:` with the verifier findings verbatim, what each round tried, and the branch + worktree left in place. A third round in this context costs more than the first two together and rarely converges, because two failed rounds usually mean the diagnosis is wrong rather than the fix.

**Acceptance-coverage check — before the PR, not after the deploy.** The standing policy (`sl-issue` step 3) is acceptance coverage by default for every feature and bug fix, with unit/integration retained underneath it. So before opening the PR, confirm one of these is true and say which:
- the change extends or adds an **AT** — `acceptance-tests/` for API/delivery behavior, `e2e/specs/*.spec.ts` for admin-UI/embed behavior — **and it has actually been run** (`scripts/run-acceptance.sh local`, or `scripts/run-e2e.sh qa`); or
- there's a **stated reason** an AT doesn't fit (pure helper, unreachable branch, not observable in a deployed env — e.g. a Micrometer counter, which has no exporter).

Neither one true → that's a finding to fix now, not a follow-up. `:acceptance-tests:acceptanceTest` is **outside `./gradlew check`**, so a green build says nothing about whether a new AT even compiles against a live target — an unrun AT is not evidence. This is what makes `sl-deploy`'s QA gate meaningful: it can only catch a regression the pack actually covers.

### 3. Open the PR
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

### 3.5 Correctness review on the open PR — `code-review`
Once the PR is up, invoke the **`code-review` plugin** via the Skill tool with the PR number as the argument:

```
Skill(skill: "code-review:code-review", args: "<PR number>")
```

It fans out its own panel (Haiku eligibility + summary, 5 parallel Sonnet reviewers across CLAUDE.md adherence / obvious bugs / git-blame history / prior-PR comments / code-comment guidance, then per-finding Haiku confidence scoring), filters to findings scoring ≥80, and posts them as a comment on the PR. A clean run posts nothing — that is a pass, not a failure.

- **Mandatory** when the change is >150 changed lines, or touches auth/permissions, credentials/secrets handling, external integration contracts, persistence/migrations, or a public API contract; below that threshold it may be skipped **with a stated reason in the ship report**.
- **Address the findings before handing back.** A confirmed **Critical/High** finding loops back to a fix + a `sl-verify` re-run (step 2), then push — don't leave a real bug sitting in a PR comment as though the review were merely advisory. Confirmed Medium/Low findings are **dropped**: leave the comment on the PR as the record and move on (`_shared/finding-disposition.md`). This step is a second, independent look at the pushed diff; step 1 already swept the working tree.
- It deliberately ignores anything a compiler, linter, or test suite would catch, assuming CI covers that. This repo has no CI (see the no-GitHub-workflows rule), so `./gradlew check` from step 2 **is** that gate — make sure it's green rather than expecting the reviewer to catch a build break.
- **Not resolvable?** `code-review:code-review` requires the plugin enabled in `~/.claude/settings.json` (`enabledPlugins`) *and* a restart since. If the Skill tool reports an unknown skill, say so in the ship report and ask the user to run `/code-review <PR#>` themselves — never substitute a self-authored review panel for it.

### 4. Hand back to `sl-issue` (when issue-driven)
End your final message with the return contract your brief asked for: the **PR URL**, the `VERIFY SUMMARY` block, the requirements table with each row's ✅/❌ and evidence, the correctness-review outcome, and any caveat or deferred requirement. Disposition every review finding per `_shared/finding-disposition.md` — Critical/High fixed in-run, Medium/Low dropped — and do **not** return a follow-up list. `sl-issue` moves the card to **"In review"** off that report — it owns the board move, and it only makes it if a PR URL came back. If verification never went green, return `SHIP-FAILED:` with the findings instead of a PR URL, so the card correctly stays in "In progress". Run standalone, there's no board interaction here.

## Output
Report: what the self-review pass changed, the verification verdict, and the PR URL — so the user can go straight into review.

## Notes
- **Independence where judgment lives**: behavioral and requirements verification is always done by an agent that didn't author the code (enforced by `sl-verify`) — don't shortcut that by judging behavior inline. Mechanical checks (build/tests/lint) run inline by design; an exit code carries no authoring bias.
- Commit + push each change without asking; the PR is the human review gate.
- Each sub-step is also runnable on its own (`sl-verify`, the PR step) when you don't need the whole pipeline.
- **One self-review pass, not two.** Step 1 (`/code-review --fix` on the tree) and step 3.5 (the plugin, on the pushed PR) are the only review passes. Findings are dispositioned by `_shared/finding-disposition.md`: **Critical/High fixed in-run, Medium/Low dropped.** A card ends when its acceptance criteria are met and nothing Critical/High is outstanding — not when every observation has a ticket.
