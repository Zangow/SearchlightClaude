---
name: sl-verify
description: Orchestrate independent verification of a Searchlight IntegrationService change — runs the mechanical checks (compile/build, tests, lint) inline, then dispatches one fresh verification agent (no authoring bias) to check real runtime behavior plus requirements traceability when the change came from an issue, and runs at most one repair round before reporting. Use after making a change and before opening a PR, or when asked to "verify my work / verify this change / make sure it works".
effort: high
---

# sl-verify — orchestrate independent, unbiased verification (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (if unset: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`). Repo checkout: `$SL_BASE_PATH/IntegrationService`. In worktree mode (`sl-issue` default) `SL_BASE_PATH` is repointed at the worktree root and `$SL_REAL_BASE` holds the true base — non-repo artifacts (requirements checklists) resolve through `${SL_REAL_BASE:-$SL_BASE_PATH}`.

Runs the full verification loop for an IntegrationService change. The point is **independence where it pays**: the judgment calls (does the change really behave as required?) are verified by a fresh agent that did not write the code, so mistakes aren't rationalized away — while deterministic checks run inline, because there is no authoring bias in an exit code.

> **Develop vs. ship.** During active iteration you usually don't need this whole orchestration — run the build/tests directly for the piece you just touched (fast). Reserve the full `sl-verify` loop (and the heavier `sl-ship` pipeline around it) for the **pre-PR pass**, not every edit.

## Core principle — independence where judgment lives, inline where it doesn't

Independence protects against **rationalization** — an author explaining away a miss. That risk only exists where a verdict takes judgment. Split the checks accordingly:

- **Mechanical checks (build, tests, lint) — run inline in the main thread.** A test suite passing is the same fact no matter who runs the command; dispatching a fresh agent to run deterministic commands pays a full repo-context bootstrap for zero independence value. Run them from a clean state and paste the real output as evidence.
- **Judgment checks (runtime behavior + requirements traceability) — one fresh agent.** Do **not** verify these inline. Launch a single verifier via the **Agent tool** (`subagent_type: sl-verify-runner` — sonnet @ medium effort by definition) and hand it:
  1. The path to this skill — tell it to read and follow the verifier checklist below exactly.
  2. The **diff** for the branch (`git -C "$SL_BASE_PATH/IntegrationService" diff main...HEAD`).
  3. The **plain-English requirement** (what the change must do) — *not* your reasoning for how you implemented it.
  4. When issue-driven, the **requirements checklist path** (step 2) — behavior and requirements are verified by the *same* agent in one pass. Both need the same context (diff + running service); a separate requirements agent would just duplicate the bootstrap, and independence is preserved either way since the verifier didn't author the code.
  5. The instruction: *"You did not write this code. Verify it against the requirement by observing real behavior. Report PASS/FAIL with evidence. Do not fix the code — report findings."*

### Model & panel policy (per `_shared/model-orchestration.md`)
- **Every verifier is an `sl-verify-runner`** (`subagent_type: sl-verify-runner`), which pins **sonnet @ effort: medium** in its definition. Verification is execution-grounded, so the tier buys little — the running service is the signal. Effort stays medium on *every* dispatch; only the **model** escalates.
- **Default:** one fresh `sl-verify-runner` on the definition's defaults. Real behavior is the signal; a single isolated verifier that actually exercises the change is enough.
- **Escalate the model, not the effort, on a high-stakes change.** When the change touches a **published API/schema contract, an external integration contract, persistence/migrations, auth/permissions, or credentials/secrets** — or exceeds **~500 changed lines** (`git diff --shortstat origin/main...HEAD`) — (this is the same trigger list `sl-ship` step 1 uses to raise review effort; keep the two in sync) override the primary to **`model: opus`** on the Agent call — the `model:` param overrides the agent definition for that one call, so you get Opus depth at the runner's medium effort. An unmet requirements row is a hard gate, so run that pass on `model: opus` too.
- **Second panelist — opt-in, not automatic:** add one extra `sl-verify-runner` (definition defaults) with a *different lens* (edge-cases / error states, vs. the primary's happy path + requirement) **only when** the user asked for a thorough pass (e.g. `--thorough`) **or** the change touches one of the high-stakes surfaces above (the size trigger alone raises the model, not a second panelist). "Multi-file" alone does not qualify — that's nearly every change.
- **Adjudicate, don't flat-vote:** reconcile the verdicts yourself if this thread is Opus, otherwise dispatch **`subagent_type: sl-adjudicator`** (opus @ high). A single-panelist flag is a *candidate* — confirm it's real before it fails the change and triggers a repair loop. An unmet requirements row is a FAIL regardless of the panel.

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
Launch the verifier as an **`sl-verify-runner`** agent (`subagent_type: sl-verify-runner`; override to `model: opus` for a contract / persistence / auth change, per the panel policy above). It must check:
- **Runtime behavior** — actually exercise the change: run the service locally, hit the changed endpoints/flows with real requests, and observe responses, logs, and error paths. A change that only passes static checks is **not verified**.
- **Requirements traceability (only when the change came from an issue):** if a requirements checklist exists at `${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md` (produced by `sl-issue`), hand the checklist path and the issue URL to the same verifier. It maps each checklist row → real evidence (code, test, endpoint response, screenshot) and marks it ✅/❌ — any unmet row is a FAIL independent of whether the technical checks pass. If the change is issue-driven and no checklist file can be found, requirements verification is **BLOCKED** — never silently skipped.
- **Test level, not just "a test exists".** The standing policy is acceptance coverage by default for any feature or bug fix (extending the spec that already covers the flow), unit/integration only where an AT genuinely doesn't fit *and* the reason is stated, and unit/integration retained even when an AT is added. For each row, note which layers back it (`AT: AdminLifecycleAcceptanceTest` + `unit: RegistrationServiceTest`). Flag — as a finding, not automatically a FAIL — any row with **no AT and no stated reason**, or an AT with **no unit/integration underneath**. A row with no test at any level is ❌ unmet. Because `:acceptance-tests:acceptanceTest` is **outside `./gradlew check`**, a new AT counts only if it was actually executed against a running target (`scripts/run-acceptance.sh local`, or `scripts/run-e2e.sh qa` for UI flows) — an AT that has never run is **BLOCKED**, not PASS.
- **Screenshots/output capture** for anything user-visible, saved to the scratchpad and referenced in the summary.

### 3. One repair round, then report
Collect verdicts. On any **FAIL**, fix the code in the main thread, then re-check — but scope the re-check to what failed and don't pay a fresh bootstrap you don't need:
1. **Mechanical failures (build/tests/lint):** re-run the failed commands inline. No agent involved.
2. **Behavioral/requirements failures:** continue the *same* verifier via `SendMessage`, scoped to the failed checks — it already has the service context, and re-checking a targeted fix carries little anchoring risk. Spawn a brand-new fresh agent only if the fix materially rewrote the behavior under test (the prior verifier's mental model no longer applies).
3. **Hard cap: 1 code-fix round.** One. If anything is still FAIL after round 1, **stop and report**; do not open a second round in this context.
4. **Only a Critical/High FAIL opens the round at all.** A FAIL that would be Medium or Low under `_shared/finding-disposition.md` — a missing edge-case test, an awkward abstraction, a slow path nobody hits, a pre-existing wart the diff brushed — is **dropped**, not repaired, exactly as it would be from a review. **When severity is ambiguous it is Medium**, so it is dropped. The repair round exists for defects that make the change wrong, not for everything a verifier noticed.

   **Three things are never Medium**, no matter how small they look: an **unmet requirements row** (the change doesn't do what the issue asked), a **failing build or test**, and a **BLOCKED** check. None of those may ever be recorded as dropped. An unmet requirement or a failing build/test opens the repair round; a **BLOCKED** check does not — it is an environment fix and a re-dispatch, which costs no round at all (see "At the cap" below). What it can never do is pass.

   A dropped FAIL does **not** stay a FAIL in the summary — there is no lawful "FAIL but ignored" state, and leaving one there deadlocks `sl-ship` and `sl-issues`, which both refuse to merge on a failed verification. Record it as **`PASS (dropped: <severity> — see Caveats)`** on its row and write the finding verbatim into `Caveats`. That is a real pass — the change is correct — carrying a disclosed, deliberately unrepaired observation. Downgrading a Critical/High to reach that spelling is the one thing this rule forbids; if you're unsure whether it qualifies, it's Medium *only* when it fails none of the three tests above.

**Why the cap is hard.** Every round appends a verifier report *and* a fix diff to your context, and each subsequent tool call re-reads all of it — so each round costs strictly more than the one before it while being strictly less likely to work. A round that didn't converge almost always means the **diagnosis** is wrong, not the fix, and another pass by the same context repeats the same wrong model of the bug. An unbounded repair loop is the single most expensive failure mode in this pipeline. If round 1 doesn't land it, a **cold** agent is both cheaper and likelier to succeed than round 2 here — that's the handoff below, not an extra round.

**At the cap:**
- **Still FAIL** → report it with the verifier's findings **verbatim**, plus what the round changed and why it didn't work. To `sl-ship`/`sl-issue` this is a failed ship, not a caveat — never round a persistent FAIL up to PASS to end the loop.
- **Genuinely close but not converged** → hand the remaining failure to **one** fresh agent (branch, failing verifier report, plain-English requirement, what round 1 already tried, and the explicit instruction to fix *and* re-run the specific failing checks itself). A cold context is both cheaper and likelier to see what the authoring head kept missing. The rules of the handoff:
  - **One handoff per run, ever.** Its own output does not earn another. If it comes back not-green, the run is a FAIL — report it.
  - **It verifies its own fix**, by re-running exactly the checks that failed. You do not re-dispatch `sl-verify-runner` behind it; that would be the second round the cap forbids.
  - **Its result replaces those rows in the VERIFY SUMMARY**, annotated `(handoff)` — e.g. `Runtime: PASS (handoff) — …`. Everything it did not touch keeps round 1's verdict. Say in `Caveats` that a handoff ran and what it changed.
  - **It is not a decision-maker.** You still own the summary and the PASS/FAIL call that `sl-ship` reads. A handoff that reports green on rows it never re-ran is a FAIL, not a PASS.
  - This is a **handoff, not a second round** — you do not stay in the loop behind it, and you do not start reviewing its diff.

- **BLOCKED on the environment** (service won't boot, missing credentials, unreachable dependency) → **does not count against the cap.** That's an env fix and a re-dispatch, not a repair round. Only rounds that changed *code* count.
- **Mechanical re-runs are free.** Re-running a failed build/test/lint command inline (case 1) is not a repair round either — the cap counts rounds that went back to the **behavioral/requirements verifier**. Likewise a compile break or a test the fix obviously broke: fix it and re-run the command. That's not a repair round, it's finishing the one you're in.

### 4. Summarize
Produce a consolidated verdict — PASS/FAIL/BLOCKED per check, what was tested at which level, evidence, screenshot paths, and any caveats. This block feeds the PR step in `sl-ship`.

**BLOCKED (could-not-verify)** — a required runtime/behavioral step could not be executed (service won't boot, missing credentials, unreachable dependency). BLOCKED is never PASS. The loop treats BLOCKED as "fix the environment and re-dispatch", not a code-fix round; never report overall green while anything is BLOCKED.

```
VERIFY SUMMARY — <branch>
Build:        PASS/FAIL/BLOCKED — …            # append " (handoff)" to any row a handoff re-ran
Tests:        PASS/FAIL/BLOCKED — <passed>/<total>
Lint:         PASS/FAIL/n-a/PASS (dropped: <sev>) — …
Runtime:      PASS/FAIL/BLOCKED/PASS (dropped: <sev>) — <what was exercised>
Requirements: PASS/FAIL/BLOCKED/n-a — <met>/<total> (n-a if not issue-driven; never "dropped")
Screenshots/output: <paths>
Caveats: <list — every dropped FAIL verbatim, plus any handoff>
```

**How a consumer reads this.** `sl-ship` and `sl-issues` gate on the row *verdicts*: any `FAIL` or `BLOCKED` anywhere blocks the PR/merge. `PASS (dropped: …)` is a **pass** for gating purposes — the Caveats text is what surfaces to the human, and it must appear in the PR body and the batch summary. That is the whole point of the spelling: a dropped Medium is disclosed, not hidden, and not a deadlock.

Do not open the PR here — that's `sl-ship`'s final step.
