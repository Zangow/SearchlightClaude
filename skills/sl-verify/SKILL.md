---
name: sl-verify
description: Orchestrate independent verification of a Searchlight IntegrationService change — runs the mechanical checks (compile/build, tests, lint) inline, then dispatches one fresh verification agent (no authoring bias) to check real runtime behavior plus requirements traceability when the change came from an issue, and loops until everything passes. Use after making a change and before opening a PR, or when asked to "verify my work / verify this change / make sure it works".
---

# sl-verify — orchestrate independent, unbiased verification (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. In worktree mode (`sl-issue` default) `SL_BASE_PATH` is repointed at the worktree root and `$SL_REAL_BASE` holds the true base — non-repo artifacts (requirements checklists) resolve through `${SL_REAL_BASE:-$SL_BASE_PATH}`.

Runs the full verification loop for an IntegrationService change. The point is **independence where it pays**: the judgment calls (does the change really behave as required?) are verified by a fresh agent that did not write the code, so mistakes aren't rationalized away — while deterministic checks run inline, because there is no authoring bias in an exit code.

> **Develop vs. ship.** During active iteration you usually don't need this whole orchestration — run the build/tests directly for the piece you just touched (fast). Reserve the full `sl-verify` loop (and the heavier `sl-ship` pipeline around it) for the **pre-PR pass**, not every edit.

## Core principle — independence where judgment lives, inline where it doesn't

Independence protects against **rationalization** — an author explaining away a miss. That risk only exists where a verdict takes judgment. Split the checks accordingly:

- **Mechanical checks (build, tests, lint) — run inline in the main thread.** A test suite passing is the same fact no matter who runs the command; dispatching a fresh agent to run deterministic commands pays a full repo-context bootstrap for zero independence value. Run them from a clean state and paste the real output as evidence.
- **Judgment checks (runtime behavior + requirements traceability) — one fresh agent.** Do **not** verify these inline. Launch a single verifier via the **Agent tool** (`general-purpose`) and hand it:
  1. The path to this skill — tell it to read and follow the verifier checklist below exactly.
  2. The **diff** for the branch (`git -C "$SL_BASE_PATH/IntegrationService" diff main...HEAD`).
  3. The **plain-English requirement** (what the change must do) — *not* your reasoning for how you implemented it.
  4. When issue-driven, the **requirements checklist path** (step 2) — behavior and requirements are verified by the *same* agent in one pass. Both need the same context (diff + running service); a separate requirements agent would just duplicate the bootstrap, and independence is preserved either way since the verifier didn't author the code.
  5. The instruction: *"You did not write this code. Verify it against the requirement by observing real behavior. Report PASS/FAIL with evidence. Do not fix the code — report findings."*

### Model & panel policy
- **Default:** one fresh verifier. Real behavior is the signal; a single capable, isolated verifier is enough.
- **Second panelist — opt-in, not automatic:** add one extra verifier on a cheaper model (`model: sonnet`) with a *different lens* (edge-cases / error states, vs. the primary's happy path + requirement) **only when** the user asked for a thorough pass (e.g. `--thorough`) **or** the change touches a published contract, persistence/migrations, or auth. "Multi-file" alone does not qualify — that's nearly every change.
- **Adjudicate, don't flat-vote:** you (main thread) reconcile the verdicts. A single-panelist flag is a *candidate* — confirm it's real before it fails the change and triggers a repair loop. An unmet requirements row is a FAIL regardless of the panel.

## Workflow

### 1. Detect what changed
```bash
git -C "$SL_BASE_PATH/IntegrationService" status --short
git -C "$SL_BASE_PATH/IntegrationService" diff --stat main...HEAD
```
Identify the surfaces the diff touches (service code, tests, config/infra, docs) and — since the repo's stack may evolve — detect the toolchain from the repo itself (build files, package manifests, CI workflows under `.github/workflows/`) rather than assuming one. Whatever CI runs is the minimum bar locally.

### 2a. Mechanical checks — inline, main thread
Run these yourself, from a clean state, using the toolchain detected in step 1:
- **Compile/build** — the project's real build command.
- **Tests** — the full test suite, plus the tests that map to the change's requirements. New behavior with no test covering it is a finding, not a pass.
- **Lint/static analysis** — whatever the repo's configured tooling is.

Record the real command output as evidence. Any failure here loops back to the author (step 3) before the behavioral agent is dispatched — don't pay for a behavioral pass on code that doesn't build.

### 2b. Behavioral + requirements pass — one fresh agent
Launch the verifier as a `general-purpose` agent (per the core principle above). It must check:
- **Runtime behavior** — actually exercise the change: run the service locally, hit the changed endpoints/flows with real requests, and observe responses, logs, and error paths. A change that only passes static checks is **not verified**.
- **Requirements traceability (only when the change came from an issue):** if a requirements checklist exists at `${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md` (produced by `sl-issue`), hand the checklist path and the issue URL to the same verifier. It maps each checklist row → real evidence (code, test, endpoint response, screenshot) and marks it ✅/❌ — any unmet row is a FAIL independent of whether the technical checks pass. If the change is issue-driven and no checklist file can be found, requirements verification is **BLOCKED** — never silently skipped.
- **Screenshots/output capture** for anything user-visible, saved to the scratchpad and referenced in the summary.

### 3. Loop until green
Collect verdicts. On any **FAIL**, fix the code in the main thread, then re-check — but scope the re-check to what failed and don't pay a fresh bootstrap you don't need:
1. **Mechanical failures (build/tests/lint):** re-run the failed commands inline. No agent involved.
2. **Behavioral/requirements failures:** continue the *same* verifier via `SendMessage`, scoped to the failed checks — it already has the service context, and re-checking a targeted fix carries little anchoring risk. Spawn a brand-new fresh agent only if the fix materially rewrote the behavior under test (the prior verifier's mental model no longer applies).
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
