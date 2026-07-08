---
name: sl-verify
description: Orchestrate independent verification of a Searchlight IntegrationService change — detects what changed on the branch, then dispatches fresh verification agents (no authoring bias) to check compile/build, tests, lint, and real runtime behavior, plus a requirements-traceability pass when the change came from an issue, and loops until everything passes. Use after making a change and before opening a PR, or when asked to "verify my work / verify this change / make sure it works".
---

# sl-verify — orchestrate independent, unbiased verification (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. In worktree mode (`sl-issue` default) `SL_BASE_PATH` is repointed at the worktree root and `$SL_REAL_BASE` holds the true base — non-repo artifacts (requirements checklists) resolve through `${SL_REAL_BASE:-$SL_BASE_PATH}`.

Runs the full verification loop for an IntegrationService change. The whole point is **independence**: the change is verified by fresh agents that did not write the code, so mistakes aren't rationalized away.

> **Develop vs. ship.** During active iteration you usually don't need this whole orchestration — run the build/tests directly for the piece you just touched (fast). Reserve the full `sl-verify` loop (and the heavier `sl-ship` pipeline around it) for the **pre-PR pass**, not every edit.

## Core principle — separate agent, fresh context

Do **not** verify your own work inline. Launch subagent(s) via the **Agent tool** (`general-purpose`) and hand each:
1. The path to this skill — tell it to read and follow the verifier checklist below exactly.
2. The **diff** for the branch (`git -C "$SL_BASE_PATH/IntegrationService" diff main...HEAD`).
3. The **plain-English requirement** (what the change must do) — *not* your reasoning for how you implemented it.
4. The instruction: *"You did not write this code. Verify it against the requirement by observing real behavior. Report PASS/FAIL with evidence. Do not fix the code — report findings."*

### Model & panel policy
Verification is grounded in **real execution**, so scale the panel to the risk:
- **Default (mechanical / low-risk change):** one fresh verifier. Real behavior is the signal; a single capable, isolated verifier is enough.
- **Logic-heavy or wide-blast-radius change:** run a small **mixed panel** — the primary verifier plus a second on a cheaper model (`model: sonnet`) given a *different lens* (one checks the happy path + requirement, the other hunts edge-cases / error states). The second voice is cheap and **decorrelates** blind spots.
- **Adjudicate, don't flat-vote:** you (main thread) reconcile the verdicts. A single-panelist flag is a *candidate* — confirm it's real before it fails the change and triggers a repair loop. An unmet requirements row is a FAIL regardless of the panel.

## Workflow

### 1. Detect what changed
```bash
git -C "$SL_BASE_PATH/IntegrationService" status --short
git -C "$SL_BASE_PATH/IntegrationService" diff --stat main...HEAD
```
Identify the surfaces the diff touches (service code, tests, config/infra, docs) and — since the repo's stack may evolve — detect the toolchain from the repo itself (build files, package manifests, CI workflows under `.github/workflows/`) rather than assuming one. Whatever CI runs is the minimum bar locally.

### 2. Dispatch verification — fresh agent(s)
Launch the verifier(s) as separate `general-purpose` agents (concurrently where independent). Each must check, as applicable:
- **Compile/build** — the project's real build command, from a clean state.
- **Tests** — the full test suite, plus the tests that map to the change's requirements. New behavior with no test covering it is a finding, not a pass.
- **Lint/static analysis** — whatever the repo's configured tooling is.
- **Runtime behavior** — actually exercise the change: run the service locally, hit the changed endpoints/flows with real requests, and observe responses, logs, and error paths. A change that only passes static checks is **not verified**.
- **Screenshots/output capture** for anything user-visible, saved to the scratchpad and referenced in the summary.

**Requirements pass (only when the change came from an issue):** if a requirements checklist exists at `${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md` (produced by `sl-issue`), dispatch a dedicated fresh agent with the checklist path, the diff, and the issue URL. It maps each checklist row → real evidence (code, test, endpoint response, screenshot) and marks it ✅/❌ — any unmet row is a FAIL independent of whether the technical checks pass. If the change is issue-driven and no checklist file can be found, requirements verification is **BLOCKED** — never silently skipped.

### 3. Loop until green
Collect verdicts. If any verifier returns **FAIL**:
1. Relay the findings to the author (you, in the main thread) and fix the code.
2. Re-dispatch verification to a *new* fresh agent (don't reuse the prior verifier's context), scoped to the failed checks.
3. Repeat until everything is PASS. Cap at ~3 rounds, then surface remaining issues to the user rather than looping forever.

### 4. Summarize
Produce a consolidated verdict — PASS/FAIL/BLOCKED per check, what was tested at which level, evidence, screenshot paths, and any caveats. This block feeds the PR step in `sl-ship`.

**BLOCKED (could-not-verify)** — a required runtime/behavioral step could not be executed (service won't boot, missing credentials, unreachable dependency). BLOCKED is never PASS. The loop treats BLOCKED as "fix the environment and re-dispatch", not a code-fix round; never report overall green while anything is BLOCKED.

```
VERIFY SUMMARY — <branch>
Build:        PASS/FAIL/BLOCKED — …
Tests:        PASS/FAIL/BLOCKED — <passed>/<total>
Lint:         PASS/FAIL/n-a — …
Runtime:      PASS/FAIL/BLOCKED — <what was exercised>
Requirements: PASS/FAIL/BLOCKED/n-a — <met>/<total> (n-a if not issue-driven)
Screenshots/output: <paths>
Caveats: <list>
```

Do not open the PR here — that's `sl-ship`'s final step.
