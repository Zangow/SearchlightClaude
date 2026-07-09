---
name: sl-ship
description: End-to-end "close the loop" orchestrator for a Searchlight IntegrationService change — runs a quality pass (simplify + code-review), independent verification (sl-verify, looping until green), then commits, pushes, and opens a review-ready PR with a Refs #n link when issue-driven. Use when a change is code-complete and you want it taken all the way to a PR, or when asked to "ship it / close the loop / finish and put up for review".
---

# sl-ship — code-complete → review-ready PR (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. In worktree mode (`sl-issue` default) `SL_BASE_PATH` is already repointed at the worktree root — everything here works unchanged.

The top-level pipeline that takes a finished change through quality, independent verification, and PR creation. Run it once the code does what's intended; it does **not** write the feature.

> **This is the final pre-PR pass — not your inner-loop check.** During active iteration, run the build/tests directly for what you just touched (fast). Reserve this full pipeline for when the change is code-complete and you're ready to open review, not after every edit.

## Pipeline

### 0. Branch guard — never ship from `main`
Before anything else, confirm the repo is on a feature branch, not `main`. Invoked via `sl-issue` it already is (branch cut up front, incremental commits). Run standalone on a code-complete change that's still sitting on `main`, **move it to a branch first**: `git -C "$SL_BASE_PATH/IntegrationService" fetch origin main && git -C "$SL_BASE_PATH/IntegrationService" switch -c <feat|fix>/<slug> origin/main`, then commit + push the work before the pipeline runs. Commit each remaining uncommitted chunk separately — don't batch into one blob commit.

### 1. Quality pass — `simplify` + `/code-review`
Invoke the built-in **`/simplify`** on the diff (reuse, simplification, efficiency, altitude). Apply its fixes. This is quality only — bug-hunting happens in verification. Additionally run **`/code-review` at `medium` effort** (higher tiers fan out their own multi-agent pass — don't pay that by default; escalate only if the user asked for a thorough review) for correctness — **mandatory** when the change is >150 changed lines, or touches auth/permissions, credentials/secrets handling, external integration contracts, persistence/migrations, or a public API contract; below that threshold it may be skipped **with a stated reason in the ship report**.

### 2. Independent verification — `sl-verify`  (loop until green)
Invoke **`sl-verify`**. It runs the mechanical checks (build, tests, lint) inline, then dispatches **one separate, unbiased agent** to verify real runtime behavior — plus requirements traceability in the same pass when the work came from an issue (pass the checklist path through). It loops — fix, re-verify — until everything is PASS. Collect its summary + evidence + caveats.

**Do not proceed to PR until verification is green.** If it can't go green within a few rounds, stop and surface the blockers to the user.

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
- **How verified** — the `VERIFY SUMMARY` block from `sl-verify`, with screenshots/output embedded or linked.
- **Caveats / follow-ups** — anything consciously deferred, including open recommendations from the quality pass.
- **`Refs #<n>`** when the work came from an issue — a plain, non-closing reference so the PR and issue cross-link. **Never `Closes`/`Fixes`/`Resolves`** — issues are closed manually on merge.
- End with the generated-with footer the harness instructions specify.

Screenshots for anything user-visible: upload via `gh` (gist or release asset — kept out of repo history) and embed inline.

### 4. Hand back to `sl-issue` (when issue-driven)
Report the PR URL back so `sl-issue` can move the card to **"In review"** (it owns the board move). Run standalone, there's no board interaction here.

## Output
Report: what simplify/code-review changed, the verification verdict, and the PR URL — so the user can go straight into review.

## Notes
- **Independence where judgment lives**: behavioral and requirements verification is always done by an agent that didn't author the code (enforced by `sl-verify`) — don't shortcut that by judging behavior inline. Mechanical checks (build/tests/lint) run inline by design; an exit code carries no authoring bias.
- Commit + push each change without asking; the PR is the human review gate.
- Each sub-step is also runnable on its own (`sl-verify`, the PR step) when you don't need the whole pipeline.
