# `skills/_shared` — helpers shared across Searchlight skills

## Rule files — one per repeated rule

Each file below owns one rule that several skills need. A skill carries a one-line pointer to it
instead of restating it, so the rule changes in one place.

| File | Rule | Pointed at from |
|------|------|-----------------|
| [`base-path.md`](./base-path.md) | resolve `$SL_BASE_PATH` / `$SL_REAL_BASE`, worktree repoint, fresh-shell exports | every sl-* skill that touches a checkout |
| [`waiting.md`](./waiting.md) | never end a turn on a pending wait; bounded waits; one Gradle run per checkout | `sl-ship`, `sl-deploy`, `sl-core-worker`, `sl-verify-runner` |
| [`card-severity.md`](./card-severity.md) | every proposed/filed card carries `Severity:` + `Why this severity:` | `sl-issues` takeaways, `sl-subtask` children |
| [`testing-policy.md`](./testing-policy.md) | AT by default, unit/integration always; only a full `./gradlew check` with a quoted test count backs green; Docker down = BLOCKED | `sl-issue`, `sl-plan`, `sl-subtask`, `sl-verify`, `sl-ship`, `sl-verify-runner` |
| [`finding-disposition.md`](./finding-disposition.md) | fix Critical/High now, drop Medium/Low (below) | `sl-ship`, `sl-issue`, `sl-issues`, `sl-verify` |
| [`model-orchestration.md`](./model-orchestration.md) | which model runs which role (below) | every skill that dispatches subagents |
| [`review-gate.md`](./review-gate.md) | plan-time review panel: roster + escalation, adjudicate, one delta round, then ask | `sl-plan` step 5, `sl-subtask` step 6 |

## `model-orchestration.md` — which Claude model runs which role

**Convention:** any skill that dispatches subagents or runs an LLM-judgment pass (plan / author /
review / verify) follows [`model-orchestration.md`](./model-orchestration.md) instead of restating
it. In short: **core roles (plan / author / adjudicate) run on Opus**; **review runs as a
fresh-thread panel mixing Opus + Sonnet**, where every reviewer *nominates* findings and a single
Opus pass *adjudicates* them — inline on the main thread when it is Opus, else `sl-adjudicator`;
**verification** is execution-grounded and defaults to one Sonnet `sl-verify-runner`, escalated to
Opus for hard gates. The rules for writing a skill — state each rule once, no exhortations, cap
subagent spawns, pin effort rather than asking for it — are its "Writing skills for Opus 5.x and
later" section. When the roster changes, edit that file only.

**Don't restate it per skill.** No skill carries its own model paragraph or a pointer banner for
this file: a skill names the agent it dispatches in its own step text (`sl-core-worker`,
`sl-depth-reviewer`, `sl-panel-reviewer`, `sl-verify-runner`, `sl-adjudicator`) and leaves the why to
`model-orchestration.md`. Which skills sit outside the policy (the mechanical ones, and `sl-deploy`
on the session model) is listed once, in its "Mechanical skills" note.

## `finding-disposition.md` — fix it now, or drop it

**Convention:** any skill that generates self-review findings about its own work follows
[`finding-disposition.md`](./finding-disposition.md) instead of restating the rule. In short:
**Critical and High get fixed in the same run, before the PR; Medium and Low get dropped.**
A new card is filed only for a Critical/High finding that is outside the card's own code, needs
a human decision or ops action, or is blocked — everything else never becomes a ticket. This
exists to stop one card from spawning an open-ended tree of follow-ups that never closes
(#248 → #268 → fifteen open follow-ups).

Reference it from a skill like:

```
> **Finding disposition:** follows `_shared/finding-disposition.md`.
```

**Applies to:** `sl-ship` (step 1 `code-review --fix` — the run's only scheduled review), `sl-issue`,
`sl-plan`, `sl-subtask`, and `sl-issues`' takeaway filing.

## Scripts

- `sl-worktree.sh` — worktree lifecycle for `sl-issue` / `sl-issues`.
- `sl-move-issue-column.sh` — move an issue's card between board columns.
- `gradle-test-count.sh <IntegrationService-dir> [suite …]` — per-suite tests/skipped/failures/errors from the JUnit XML; the count `testing-policy.md` §3 requires (Gradle's console prints none here).
- `gradle-busy.sh <repo-dir> [--wait 1..540]` — is another Gradle run live over this checkout? exit 0 clear · 4 busy · 2 usage. Never kills anything (`waiting.md` rule D).
- `test-gradle-scripts.sh` — hermetic tests for the two above (`bash skills/_shared/test-gradle-scripts.sh`).
