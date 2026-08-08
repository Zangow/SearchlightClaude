---
name: sl-issues
description: Batch front door over `sl-issue` — takes one or more Searchlight IntegrationService issue numbers/URLs (space-delimited, e.g. `/sl-issues 171 173 186`), expands each into its native GitHub sub-issues (recursively, parent-first), drops anything CLOSED or already ASSIGNED (to anyone, including you — that means it's already been picked up), and works the remaining queue ONE AT A TIME. Per item it assigns the issue to you, dispatches a fresh context-isolated subagent to run `/sl-issue` on it, reports that run's results (PR, requirements, caveats, follow-ups) back for you to interact with, then offers to merge the PR and remove the worktree before asking whether to start the next one. Use when asked to "work issues 1 2 3", "run this batch of Searchlight tickets", "do issue X and its subtasks", or when handed several issue numbers to implement end-to-end.
---

# sl-issues — batch queue over `sl-issue` (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (the parent dir of the IntegrationService repo). If unset, set it first in every shell snippet: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`.

This skill **does not implement anything itself**. It is a queue driver: it expands the issues you name into a full work list (each issue **plus its sub-issues**), then walks that list one item at a time, handing each item to a **fresh subagent that runs `/sl-issue`** in its own context. You stay in the loop between items — you see each run's results, decide whether to merge, and say when to start the next.

**Why one at a time, in order:** each `sl-issue` run cuts its worktree branch off freshly-fetched `origin/main`. Merging item N before starting item N+1 is what makes N+1's base contain N's work — which matters constantly here, because a parent and its sub-issues usually touch the same config, the same Flyway migration chain, or the same acceptance-test class.

## Inputs
Space-delimited issue numbers and/or URLs — `/sl-issues 171`, `/sl-issues 173 186 187`, `/sl-issues 171 https://github.com/Zangow/IntegrationService/issues/173`. A bare number (with or without `#`) **defaults to `Zangow/IntegrationService`**. If no issue was given, ask for it.

**Flags** (passed straight through to each `sl-issue` run): `--skip-worktree`.

## 1. Expand the queue
For **each** issue named, pull the issue and its native GitHub sub-issues, recursively:

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$n:Int!){
  repository(owner:$owner,name:$repo){
    issue(number:$n){
      number title state url assignees(first:10){nodes{login}}
      subIssues(first:50){ totalCount nodes{
        number title state url assignees(first:10){nodes{login}}
        subIssues(first:50){ totalCount nodes{
          number title state url assignees(first:10){nodes{login}} }}
      }}
    }
  }
}' -F owner=Zangow -F repo=IntegrationService -F n=<n>
```
If any `subIssues.totalCount` exceeds the nodes returned (or a third level itself has children), re-query that child directly — never silently truncate a level. Big epics here really do carry 15–20 children (e.g. #173's AT pack), so check the counts rather than eyeballing the list.

**Ordering: depth-first, parent before its children, in the order you were given them.** So `171 (no subs), 173 (subs 174, 175), 200 (sub 201)` becomes the queue `171, 173, 174, 175, 200, 201`.

**Dedupe by issue number**, keeping the first occurrence — a listed issue that is also another listed issue's sub-issue appears once.

## 2. Filter the queue: eligible = OPEN and UNASSIGNED
An item is worked **only** if it is both:
- **`state: OPEN`** — a closed issue is finished work, never re-opened work; and
- **assigned to nobody** — `assignees` is empty. **Any** assignee disqualifies it, *including the current user* — an issue already assigned to you means you (or an earlier session) already picked it up, and this skill must not redo it.

Everything else is **dropped from the queue and reported**, never silently worked:

| Dropped because | Reported as |
|---|---|
| `state: CLOSED` | already done — skipped |
| assigned to the current user | already picked up by you — skipped |
| assigned to anyone else | owned by `<login>` — skipped |

## 3. Present the queue + clear the batch-level questions
Show two tables: the **eligible queue** (position, `#`, title, parent) and the **dropped** items (`#`, title, reason from above). Also flag, in the eligible table:

- **an umbrella parent** — a parent whose body carries no acceptance criteria of its own and whose work is entirely in its children (common on this board: the epic states the theme, each child states one testable outcome). Don't guess at work that isn't there; flag it so the user can drop it from the queue.

Then resolve everything in **one** `AskUserQuestion` round: whether to drop any flagged umbrella parent, and whether to **force any dropped item back in** (the drop rules are the default, and the user can always override a specific one — e.g. an issue assigned to them that they genuinely want re-run). If nothing is eligible after filtering, say so and stop; there's nothing to work.

There is **no end-column question** — the Searchlight board contract is fixed: `In progress` on start, `In review` when the PR is up. Start item 1 — no further gate.

## 4. Per item: claim → dispatch → report → merge → next

### 4a. Re-check eligibility, then claim the issue
The queue may be minutes or hours old, so **re-apply the step-2 rule at pickup** — still `OPEN`, still unassigned — before claiming:
```bash
gh issue view <n> --repo Zangow/IntegrationService --json state,assignees,title
# eligible only if .state == "OPEN" and .assignees == []
gh issue edit <n> --repo Zangow/IntegrationService --add-assignee @me
```
If it was closed or picked up in the meantime, **don't work it** — report the change and move to step 4e (next item). `sl-issue` also assigns `@me` — that's a harmless no-op; this earlier claim is the gate that stops a second session grabbing the same ticket mid-run.

### 4b. Dispatch a fresh `/sl-issue` subagent  ← new thread, clean context
One subagent per item, **`subagent_type: general-purpose`**, **`model: opus`** (authoring is a core role), **`run_in_background: false`** — you need the result before continuing, and the queue is deliberately serial. Nothing from the previous item leaks into this one.

The subagent prompt must carry:
1. **The invocation**: "Invoke the `sl-issue` skill (Skill tool, `skill: sl-issue`) with `<n>` *(plus `--skip-worktree` if the user passed it)* and follow it end to end."
2. **The no-interaction rule**: "You cannot reach the user. If you hit a requirement that is ambiguous in a way that changes *what* to build, do **not** guess and do **not** proceed — stop and return `BLOCKED:` followed by the specific question and the concrete options you'd offer. Resolve pure implementation choices yourself."
3. **Batch context** when it matters: "This is item `<i>` of `<N>`; item `<i-1>` (#`<prev>`) is <merged | open in PR #X and NOT merged, so your `origin/main` base does not contain it>." Call out explicitly when the previous item added a **Flyway migration** — the next item must not reuse that version number.
4. **The report contract** — end your final message with: issue title + URL; PR URL; the requirements checklist with each row's ✅/❌ and evidence; verification verdict; whether an `sl-plan` plan of record was adopted (and what drifted if amended); confirmation the card moved to "In review"; the worktree root path and whether it was removed; and explicitly — **caveats, deferred/out-of-scope requirements, and follow-ups worth filing**, plus the **ops footprint** (`### Ops / rollout`): does this need a backend/UI/embed/infra **deploy**, does it add a **Flyway migration**, and which live integration configs must be **republished** afterwards.

### 4c. Report back to the user
Relay the run's outcome in the terminal — the subagent's report is **not** shown to the user, so surface it yourself: PR URL, the requirements table with ✅/❌, the verify verdict, the worktree path, the card's column, and **every caveat and follow-up, up front rather than buried**. Always call out the **ops footprint** (deploy / migration / configs to republish) — that's what turns a merged PR into a working change, and it's the easiest thing to lose in a batch. Then stop and let the user respond — questions, corrections, "change this before merging" — this is their interaction point.

**If the run came back `BLOCKED:`** — put the question to the user with `AskUserQuestion` (using the options the subagent proposed), post the answer back onto the GitHub issue as a comment so the ticket stays the source of truth (`gh issue comment <n> --repo Zangow/IntegrationService --body "Clarified scope: …"`), then **resume that same subagent** with `SendMessage` to its agent ID so it continues with its context intact — do not spawn a fresh one and pay for the whole context again.

**If the user wants changes** to the delivered work, send them to the same agent with `SendMessage` too; it still has the worktree, the branch, and the checklist.

### 4d. Offer merge + cleanup
Once the user is satisfied, offer it — never merge unprompted. Check mergeability first:
```bash
gh pr view <pr> --repo Zangow/IntegrationService \
  --json number,title,mergeable,mergeStateStatus,statusCheckRollup,headRefName
```
Report anything not cleanly mergeable (conflicts, failing checks) and **do not merge** it without an explicit override. Note that this repo has **no GitHub Actions workflows** — an empty `statusCheckRollup` is expected, not a red flag; the quality gate is the locally-run `./gradlew check` that `sl-ship` records on the PR.

Offer with one `AskUserQuestion` (`multiSelect: true`): *Merge the PR* / *Remove the worktree* / *Close the issue + move the card to "Done"* / *Leave everything as is*.

- **Merge — IntegrationService uses merge commits** (its history is `Merge pull request #<pr> from Zangow/<branch>`, not squashes):
  ```bash
  gh pr merge <pr> --repo Zangow/IntegrationService --merge
  ```
  PRs use `Refs #<n>`, so merging **does not** close the issue — that stays a deliberate, separate choice below.
- **Worktree cleanup** — after merging, not before (the branch must be on the remote and merged):
  ```bash
  WT="${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-worktree.sh"
  "$WT" env-release            # only if this run still holds the local-env lock
  "$WT" remove issue-<n>-<slug>
  ```
  Never `--force` a worktree with uncommitted changes without confirming. If a local branch delete later complains the branch is checked out, it's because the worktree is still there — remove the worktree first.
- **Close the issue** only if explicitly chosen (the team's convention is to close manually on merge):
  ```bash
  gh issue close <n> --repo Zangow/IntegrationService
  "${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-move-issue-column.sh" Zangow/IntegrationService <n> "Done"
  ```

**Deploying is not part of this skill.** Merging lands the code on `main`; getting it into QA/PROD is `/sl-deploy`, and republishing affected integration configs is a separate ops step. Say which items in the batch need one, and let the user decide when — batching several merges and deploying once at the end is usually the right call.

**If the user declines the merge**, say plainly what it costs: the next item branches off `origin/main` without this work. Carry that into the next subagent's prompt (point 3 above) so it knows its base is missing the parent's code.

### 4e. Ask before the next item
> **Ready for the next one?** — next up is `#<n>: <title>` (item `<i+1>` of `<N>`).

Offer *Start it* / *Skip it and go to the one after* / *Stop here*. On confirmation, go back to **4a** for that item. Never roll straight into the next item unprompted.

## 5. Final summary
When the queue is exhausted (or the user stops), print one table over every item: `#`, title, outcome (shipped / blocked / skipped / stopped), PR URL, merged?, worktree removed?, board column. Below it, list **every caveat and follow-up** collected across the runs, plus the **combined ops footprint** for the batch — what needs deploying, which migrations landed, and which live configs must be republished. Those are the easiest things to lose in a long batch, and they're usually the reason the next ticket exists.

## Notes
- **This skill never writes feature code.** Every implementation decision belongs to the `sl-issue` subagent; this skill expands, filters, claims, dispatches, relays, and gates.
- **Serial by design.** `sl-issue` supports parallel authoring via worktrees, but a batch is a dependency chain far more often than not — especially Flyway version numbers, which collide silently when two branches off the same `main` each add one. One at a time, merged in between.
- **Fresh context per item is the point.** Each item gets its own subagent so requirements, file paths, and half-formed assumptions from item N never bleed into item N+1.
- **The three pauses are load-bearing**: the queue round up front (step 3), the results review (4c), and merge + next (4d/4e). Everything between them runs without stopping.
- **`BLOCKED:` is resumed, not restarted** — `SendMessage` back to the same agent keeps the worktree, branch, and checklist alive.
- **Board and assignee updates are conveniences, not gates.** If a board move or assignee add fails (usually missing gh scopes — `gh auth refresh -s read:project,project`), surface it and keep going.
