# `skills/_shared` — helpers shared across Searchlight skills

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
