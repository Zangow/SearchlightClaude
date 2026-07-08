---
name: sl-issue
description: Front door that turns a Searchlight IntegrationService GitHub issue into a shipped PR — pulls the issue (title, body, comments, labels) via gh, assigns it to the user and moves its card to "In progress" on the Searchlight Integration Service board, extracts a structured requirements checklist, plans and implements the change, then runs the full sl-ship pipeline (quality → independent verify → PR) with a requirements-traceability gate and a Refs #n link so the PR cross-links the issue (without auto-closing it). On completion it moves the card to "In review". Use when asked to "/sl-issue <n> / work this Searchlight issue / pick up IntegrationService issue <n>".
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
Plan the change against the checklist (consider the `Plan` agent for non-trivial work). Planning and authoring are **core roles — keep them on the strongest available model**; reserve cheaper models for the review/verify panels downstream.

**Plan-review gate (non-trivial issues).** If the planned change is multi-file, adds a new endpoint/contract/integration, or touches persistence, dispatch a fresh plan reviewer (Agent tool, `general-purpose`) before writing code. Hand it the issue, the requirements checklist, and your written plan; ask: will this plan meet every checklist row? what will break? what's simpler? Fold blockers into the plan before implementing.

**Derive tests from the checklist, not the code.** Turn each testable checklist row into a named test (`R3 → test('…')`) so the requirements pass in `sl-verify` maps rows → tests directly. Post-hoc tests encode what the code *does*, not what the issue *required*.

Keep the checklist open as your definition of done — every `☐` must be addressed by code (or explicitly moved to out-of-scope with a reason).

**Commit + push after each completed step** (a checklist row or a coherent chunk) — don't batch everything into one commit at the end:
```bash
git -C "$SL_BASE_PATH/IntegrationService" add -A
git -C "$SL_BASE_PATH/IntegrationService" commit -m "<imperative subject>" -m "<short body: what + why, Refs #<n>>"
git -C "$SL_BASE_PATH/IntegrationService" push
```
Imperative subject scoped to the step, a one-line body, and a `Refs #<n>` trailer. End the commit body with the Co-Authored-By trailer the harness instructions specify for the current model.

### 4. Ship it — `sl-ship`  (with the checklist threaded in)
Invoke **`sl-ship`** on the finished change. Tell it this work originated from issue `#<n>` and pass the **path to the requirements checklist**. sl-ship runs its pipeline — quality (`simplify` + `/code-review`) → `sl-verify` (looping until green, including the requirements-traceability pass) → PR — and:
- **`sl-verify`** maps each checklist row → real evidence (code/test/endpoint response/screenshot) and marks it ✅/❌. Any unmet requirement is a FAIL that loops back to step 3, exactly like a surface failure.
- The PR embeds the satisfied-requirements table and adds the **`Refs`** link (step 5).

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
Report: the issue title + URL, the requirements checklist with each row's final ✅/❌ and evidence, the verification verdict, the PR URL with its `Refs` link, and confirmation the card moved to **"In review"**. Surface any requirement you moved out of scope up front, and remind the user the issue is **linked but not auto-closed** — they close it on merge. In worktree mode (the default), also report the worktree root path and whether you removed it or left it on disk.

## Notes
- **Autonomy boundary**: implement and ship without stopping; the only allowed pause is **up front, before implementation** — a requirement that's ambiguous in a way that changes *what* gets built. Record the answer back on the GitHub issue so the ticket stays the source of truth. After that, run straight through; the PR is the review gate.
- **Board status is a convenience, not a gate**: "In progress" / "In review" moves never block the actual change.
- The checklist is the contract. An unaddressed row is a FAIL, not a caveat.
- Each downstream step is still runnable on its own; `sl-issue` just adds fetch + author in front of `sl-ship`.
