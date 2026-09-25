---
name: sl-verify
description: Orchestrate independent verification of a Searchlight IntegrationService change — runs the mechanical checks (compile/build, tests, lint) inline, then dispatches one fresh verification agent (no authoring bias) to check real runtime behavior plus requirements traceability when the change came from an issue, and runs at most one repair round before reporting. Use after making a change and before opening a PR, or when asked to "verify my work / verify this change / make sure it works".
effort: high
---

# sl-verify — orchestrate independent, unbiased verification (Searchlight)

> **Repo paths use `$SL_BASE_PATH`** — resolve it per `_shared/base-path.md`.

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

### Model & panel policy
Verifier dispatch — `sl-verify-runner` by type, model-only escalation, the opt-in second panelist, and inline adjudication with `sl-adjudicator` as the non-Opus fallback — follows `_shared/model-orchestration.md` "Verification panel".
- **Escalation trigger:** the change touches a **published API/schema contract, an external integration contract, persistence/migrations, auth/permissions, or credentials/secrets** — or exceeds **~500 changed lines** (`git diff --shortstat origin/main...HEAD`). This is the only copy of the list: `sl-ship` step 1 raises review effort on it and `_shared/finding-disposition.md` points here, so a diff that escalates the verifier escalates the review.

## Workflow

### 1. Detect what changed
```bash
git -C "$SL_BASE_PATH/IntegrationService" status --short
git -C "$SL_BASE_PATH/IntegrationService" diff --stat main...HEAD
```
Identify the surfaces the diff touches (service code, tests, config/infra, docs, `ui/`, `ui-embed/`) and read the toolchain from the repo itself (build files, package manifests) rather than assuming one. There is no CI to mirror — step 2a is the whole mechanical bar.

### 2a. Mechanical checks — inline, main thread
> **Testing policy:** the evidence rules are `_shared/testing-policy.md` §3 — only a full `./gradlew check` backs green, never `-q`, and a quoted test count, never a bare `BUILD SUCCESSFUL`.

Run these yourself from a clean state, in this order:
1. **Preconditions.** `docker info >/dev/null 2>&1` — Docker down makes `Tests` **BLOCKED**, not FAIL. Start Docker and re-run; don't substitute `./gradlew test`. Then `"${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/gradle-busy.sh" "$SL_BASE_PATH/IntegrationService"`: exit 4 means another Gradle run is live in this checkout, so wait it out per `_shared/waiting.md` rule D.
2. **Build + tests + lint — one full `./gradlew check`** in `$SL_BASE_PATH/IntegrationService` (`--console=plain`, no `-q`). It covers compile, `test`, `integrationTest`, `boundedHeapTest`, the script tests and `:acceptance-tests:test`. Run it through the rc wrapper in `_shared/waiting.md` rule B; a full `check` outlives a single foreground call. `check` does not build the front-ends: when the diff touches `ui/` or `ui-embed/`, also run that package's `npm run typecheck`, `lint`, `test` and `build`, and quote the test runner's count.
3. **Read the count.** `"${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/gradle-test-count.sh" "$SL_BASE_PATH/IntegrationService"`. Quote its per-suite lines as the `Tests` evidence. Check that the tests mapped to this change's requirements appear among the executed tests, not the skipped ones. The script prints totals only, so find them in the suite's `build/test-results/<suite>/TEST-<class>.xml` (a skipped case carries a `<skipped/>` child). New behaviour with no test covering it is a finding, not a pass.

Any failure here loops back to the author (step 3) before the behavioral agent is dispatched — don't pay for a behavioral pass on code that doesn't build.

### 2b. Behavioral + requirements pass — one fresh agent
Launch the verifier as an **`sl-verify-runner`** agent (`subagent_type: sl-verify-runner`; override to `model: opus` on any escalation trigger above, and whenever a requirements checklist is passed — this agent runs the requirements pass too). It must check:
- **Runtime behavior** — actually exercise the change: run the service locally, hit the changed endpoints/flows with real requests, and observe responses, logs, and error paths. A change that only passes static checks is **not verified**.
- **Requirements traceability (only when the change came from an issue):** if a requirements checklist exists at `${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-issue/REQUIREMENTS-<n>.md` (produced by `sl-issue`), hand the checklist path and the issue URL to the same verifier. It maps each checklist row → real evidence (code, test, endpoint response, screenshot) and marks it ✅/❌ — any unmet row is a FAIL independent of whether the technical checks pass. If the change is issue-driven and no checklist file can be found, requirements verification is **BLOCKED** — never silently skipped.
- **Test level, not just "a test exists"** (policy: `_shared/testing-policy.md` §1). For each row, note which layers back it (`AT: AdminLifecycleAcceptanceTest` + `unit: RegistrationServiceTest`). A row with **no AT and no stated reason**, or an AT with **no unit/integration underneath**, is a finding, not automatically a FAIL. A row with no test at any level is ❌ unmet. A new AT counts only once it has executed against a running target (`scripts/run-acceptance.sh local`, or `scripts/run-e2e.sh local|qa` for UI flows) and its count has been read. An AT that has never run is **BLOCKED**, not PASS.
- **Screenshots/output capture** for anything user-visible, saved to the scratchpad and referenced in the summary.

### 3. One repair round, then report
Collect verdicts. On any **FAIL**, fix the code in the main thread, then re-check — but scope the re-check to what failed and don't pay a fresh bootstrap you don't need:
1. **Mechanical failures (build/tests/lint):** re-run the failed commands inline. No agent involved.
2. **Behavioral/requirements failures:** continue the *same* verifier via `SendMessage`, scoped to the failed checks — it already has the service context, and re-checking a targeted fix carries little anchoring risk. Spawn a brand-new fresh agent only if the fix materially rewrote the behavior under test (the prior verifier's mental model no longer applies).
3. **Hard cap: 1 code-fix round.** One. If anything is still FAIL after round 1, **stop and report**; do not open a second round in this context.
4. **Only a Critical/High FAIL opens the round at all.** A FAIL that would be Medium or Low under `_shared/finding-disposition.md` — a missing edge-case test, an awkward abstraction, a slow path nobody hits, a pre-existing wart the diff brushed — is **dropped**, not repaired, exactly as it would be from a review. **When severity is ambiguous it is Medium**, so it is dropped. The repair round exists for defects that make the change wrong, not for everything a verifier noticed.

   **Three things are never Medium**, no matter how small they look: an **unmet requirements row** (the change doesn't do what the issue asked), a **failing build or test**, and a **BLOCKED** check. None of those may ever be recorded as dropped. An unmet requirement or a failing build/test opens the repair round; a **BLOCKED** check does not — it is an environment fix and a re-dispatch, which costs no round at all (see "At the cap" below). What it can never do is pass.

   A dropped FAIL does **not** stay a FAIL in the summary — there is no lawful "FAIL but ignored" state, and leaving one there deadlocks `sl-ship` and `sl-issues`, which both refuse to merge on a failed verification. Record it as **`PASS (dropped: <severity> — see Caveats)`** on its row and write the finding verbatim into `Caveats`. That is a real pass — the change is correct — carrying a disclosed, deliberately unrepaired observation. Downgrading a Critical/High to reach that spelling is the one thing this rule forbids; if you're unsure whether it qualifies, it's Medium *only* when it fails none of the three tests above.

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
Tests:        PASS/FAIL/BLOCKED — ./gradlew check: <gradle-test-count.sh lines: suite executed/tests, failures, errors> (never a bare BUILD SUCCESSFUL)
Lint:         PASS/FAIL/n-a/PASS (dropped: <sev>) — …
Runtime:      PASS/FAIL/BLOCKED/PASS (dropped: <sev>) — <what was exercised>
Requirements: PASS/FAIL/BLOCKED/n-a — <met>/<total> (n-a if not issue-driven; never "dropped")
Screenshots/output: <paths>
Caveats: <list — every dropped FAIL verbatim, plus any handoff>
```

**How a consumer reads this.** `sl-ship` and `sl-issues` gate on the row *verdicts*: any `FAIL` or `BLOCKED` anywhere blocks the PR/merge. `PASS (dropped: …)` is a **pass** for gating purposes — the Caveats text is what surfaces to the human, and it must appear in the PR body and the batch summary. That is the whole point of the spelling: a dropped Medium is disclosed, not hidden, and not a deadlock.

Do not open the PR here — that's `sl-ship`'s final step.
