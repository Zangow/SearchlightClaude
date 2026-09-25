# `skills/_shared` — helpers shared across Searchlight skills

## Rule files — one per repeated rule

Each file below owns one rule that several skills need. A skill carries a one-line pointer to it
instead of restating it, so the rule changes in one place.

| File | Rule | Pointed at from |
|------|------|-----------------|
| [`base-path.md`](./base-path.md) | resolve `$SL_BASE_PATH` / `$SL_REAL_BASE`, worktree repoint, fresh-shell exports | every sl-* skill that touches a checkout |
| [`waiting.md`](./waiting.md) | never end a turn on a pending wait; bounded waits; one Gradle run per checkout | `sl-ship`, `sl-deploy`, `sl-core-worker`, `sl-verify-runner` |
| [`card-severity.md`](./card-severity.md) | every proposed/filed card carries `Severity:` + `Why this severity:` | `sl-issues` takeaways, `sl-subtask` children |
| [`finding-disposition.md`](./finding-disposition.md) | fix Critical/High now, drop Medium/Low (below) | `sl-ship`, `sl-issue`, `sl-plan`, `sl-subtask`, `sl-issues` |
| [`model-orchestration.md`](./model-orchestration.md) | which model runs which role (below) | every skill that dispatches subagents |

## `model-orchestration.md` — which Claude model runs which role

**Convention:** any skill that dispatches subagents or runs an LLM-judgment pass (plan / author /
review / verify) follows the model-assignment policy in
[`model-orchestration.md`](./model-orchestration.md) instead of restating it.

Reference it from a skill like:

```
> **Model assignment:** follows `_shared/model-orchestration.md`.
```

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
