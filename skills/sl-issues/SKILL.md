---
name: sl-issues
description: Batch front door over `sl-issue` — takes one or more Searchlight IntegrationService issue numbers/URLs (space-delimited, e.g. `/sl-issues 171 173 186`), expands each into its native GitHub sub-issues (recursively, parent-first), drops anything CLOSED or already ASSIGNED (to anyone, including you — that means it's already been picked up), and works the remaining queue ONE AT A TIME. Per item it assigns the issue to you, dispatches a fresh context-isolated subagent to run `/sl-issue` on it, reports that run's results (PR, requirements, caveats, follow-ups) back for you to interact with, then offers to merge the PR and remove the worktree before asking whether to start the next one. Pass `--keepGoing` to run the whole batch autonomously instead — no pauses at all: each run's takeaways are filed as new cards under the same parent (critical ones inserted next in the queue, the rest appended), and every item is closed out automatically (merge the PR, close the issue, move the card to Done, remove the worktree). Use when asked to "work issues 1 2 3", "run this batch of Searchlight tickets", "do issue X and its subtasks", or when handed several issue numbers to implement end-to-end.
---

# sl-issues — batch queue over `sl-issue` (Searchlight)

> **Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` (the parent dir of the IntegrationService repo). If unset, set it first in every shell snippet: `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`.

This skill **does not implement anything itself**. It is a queue driver: it expands the issues you name into a full work list (each issue **plus its sub-issues**), then walks that list one item at a time, handing each item to a **fresh subagent that runs `/sl-issue`** in its own context. You stay in the loop between items — you see each run's results, decide whether to merge, and say when to start the next.

**Why one at a time, in order:** each `sl-issue` run cuts its worktree branch off freshly-fetched `origin/main`. Merging item N before starting item N+1 is what makes N+1's base contain N's work — which matters constantly here, because a parent and its sub-issues usually touch the same config, the same Flyway migration chain, or the same acceptance-test class.

## Inputs
Space-delimited issue numbers and/or URLs — `/sl-issues 171`, `/sl-issues 173 186 187`, `/sl-issues 171 https://github.com/Zangow/IntegrationService/issues/173`. A bare number (with or without `#`) **defaults to `Zangow/IntegrationService`**. If no issue was given, ask for it.

**Flags:**
- `--skip-worktree` — passed straight through to each `sl-issue` run.
- `--keepGoing` (also accepted: `--keep-going`) — **driver-level, not passed to the child run.** Turns the batch autonomous: no pauses, takeaways filed as cards and folded back into the queue, and each item closed out (merge → complete → worktree removed) without asking. See below.

**Concurrency is capped at 4 subagents in flight per item, flag or no flag** — see 4b.

## `--keepGoing` — autonomous batch mode

Without the flag this skill pauses three times per item and the user decides. With `--keepGoing` it **never pauses**: it makes the default choice at every gate, keeps working until the queue is exhausted, and reports once at the end.

**What the user is trading away by passing it.** State this in one line when the batch starts, then don't repeat it: the results-review pause (4c) and the merge gate (4d) are where a wrong-but-plausible run normally gets caught, and `--keepGoing` removes both — work merges to `main` on the strength of the run's own verification and nothing else. That is the point of the flag, not a reason to second-guess it; it is opt-in and the user asked for it.

**The four rules that replace the pauses:**

1. **Never ask — take the default.** Step 3's question round is skipped: dropped items stay dropped, and an umbrella parent is dropped **only if it arrived as a sub-issue of something else**. A parent the user *named on the command line* is worked — silently discarding work they explicitly typed is not a default you get to take. Say what you defaulted to, and move on.
2. **File takeaways as cards** (below) instead of surfacing them for a human to triage.
3. **Close out every item automatically**: merge the PR, close the issue, move the card to `Done`, remove the worktree — in that order, per item, before starting the next.
4. **Never guess on a `BLOCKED:` run.** Autonomy removes the *pauses*, not the *judgement*. A blocked run is not resolved by picking an option — see "When an item can't close out cleanly".

### Filing takeaways

After each run, read the report's caveats / deferred requirements / follow-ups. **File it if it names a specific defect, gap, or deferred requirement with evidence.** Don't file "we should look into X" — that is a line for the final summary, not a card. One card per takeaway, in the same repo, linked as a **native sub-issue of the same parent** the current item hangs off (the batch root when the item has no parent).

**Before filing, check it against the cards this batch has already filed.** If it is the same substance as an existing one, comment on that card instead — two runs noticing the same missing index must not produce two cards.

```bash
export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"
REPO=Zangow/IntegrationService

# 1. create the card
URL=$(gh issue create --repo "$REPO" \
  --title "<takeaway title>" \
  --body "$(cat <<'EOF'
Filed automatically by `/sl-issues --keepGoing` from the run on #<item>.

**Surface:** … · **Change type:** … · **Flyway migration:** … · **Deploy needed:** … · **Live configs to republish:** …

## Summary
<what the run found, in its own evidence — file:line, not a paraphrase>

## Why it matters
<the consequence, concretely>

## Acceptance criteria
- [ ] …

Found while working #<item>.
EOF
)")
NEW=${URL##*/}

# 2. link it under the same parent — REST, same call sl-subtask uses
CHILD_ID=$(gh api "repos/$REPO/issues/$NEW" --jq .id)     # database id, NOT the node id
gh api --method POST "repos/$REPO/issues/<parent>/sub_issues" -F sub_issue_id="$CHILD_ID"
```

Two REST calls, no GraphQL — the Projects/GraphQL quota is the first thing to run out in a long batch, and this is the same call `sl-subtask` makes. `<item>` / `<parent>` are placeholders you fill in when you write the command, which is why the heredoc delimiter is quoted.

Write a **real card**, not a stub — the run has the evidence in hand and this is the only moment it exists. Leave a header field as `unknown` rather than guessing it. A takeaway filed as "investigate the thing" is worse than not filing it.

### Where a takeaway goes in the queue

| Kind | Test | Queue position |
|---|---|---|
| **Critical** | It causes **data loss or corruption**; it is a **security exposure**; it **breaks `main` or a deploy**; it **blocks or invalidates a later item in this queue**; or it makes a **just-shipped card's acceptance criteria untrue**. | **Inserted as the next item** — worked before anything else, because everything after it is built on the problem. |
| Everything else | Real, worth doing, but the queue is still correct without it. | **Appended to the end** of the queue. |
| **Not workable by an agent** — its body is a question for the user, a decision only they can make, or an ops action (a deploy, an irreversible publish) | Regardless of how critical it is. | **Filed, never enqueued.** It goes in the final summary's decision list. Dispatching a run at an unanswerable question just burns an Opus run and invites the guess rule 4 forbids. |

When in doubt it is **not** critical — a wrongly-promoted card reorders the batch and starves the work the user actually asked for. Inserted criticals are worked exactly like any other item: step 4a re-check, claim, dispatch.

### Keeping the queue bounded

The queue is mutable, so it needs real limits. Track, in-session, **the list of cards this batch filed** — that list is the marker, not a label (don't invent one; `takeaway` does not exist in this repo and `gh` hard-fails on an unknown label, which would abort the create).

- **Depth:** a card this batch filed may itself file takeaways, but those are **filed only, never enqueued** — the queue grows at most one level deep from what the user asked for.
- **Breadth:** enqueue at most **2 takeaways per item**, and stop enqueuing entirely once the queue has grown past **2× its original length**. File the rest and list them.
- **Circuit breaker:** after **3 consecutive items that fail to close out cleanly**, stop the batch and report. Something systemic is wrong — usually a bad merge on `main` that every later base now carries, in which case continuing just burns the queue filing one critical card per item.

Report everything filed-but-not-enqueued, and any cap you hit, in the final summary.

### When an item can't close out cleanly

Autonomy is not "merge regardless". In each of these cases: **do not merge, leave the worktree in place, file a takeaway card recording exactly what happened, and continue to the next item.** Carry the fact into the next subagent's prompt, because its base won't contain this item's work.

- The run returned **`BLOCKED:`** — file the blocking question and the options it proposed, verbatim. **Don't answer it, and don't enqueue it** (see the third row above).
- The run **produced no PR** — it crashed, timed out, or returned a report with no PR URL. There is nothing to merge; don't reach for a `<pr>` that doesn't exist.
- The run returned **`SHIP-FAILED:`** — its ship agent hit `sl-verify`'s 2-round repair cap without going green. File the verifier findings verbatim as the takeaway card. **Don't re-dispatch the item to burn a third round**: two rounds that didn't converge mean the diagnosis is wrong, and a fresh full run pays for the whole issue again to reach the same wall. It needs a human or a targeted follow-up card, not a retry.
- The PR is **not cleanly mergeable** (conflicts, `mergeStateStatus` not clean).
- **`gh pr merge` itself fails** after a clean pre-check — branch protection, or a push that landed in between. Stop the close-out block there: do **not** close the issue or move the card.
- The run reported a **failed or missing verification**, or a red `./gradlew check`.
- The run reports its own requirements as **not met** (❌ rows with no stated justification).

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

**With `--keepGoing`:** skip the question round entirely. Drop flagged umbrella parents, leave dropped items dropped, print both tables plus one line naming the defaults you took and the one-line trade-off note, and start item 1.

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

**Concurrency budget — cap the fan-out inside the item.** The queue being serial bounds *your* dispatches to one at a time, but it does **not** bound the child's: `sl-issue` calls `sl-ship`, which runs a multi-agent `code-review` panel and `sl-verify`, each of which can fan out again. Nested panels multiply, and a single item has been seen running dozens of threads at once — which mostly buys contention, not throughput. Two gradle builds in one worktree alone fake a ~60-class failure.

So the prompt must impose a hard ceiling: **at most 4 subagents in flight at any moment for the whole item, counting every nested level.** Beyond that, run them in waves rather than widening. Put it in the prompt verbatim:

> **Concurrency limit: at most 4 subagents running at any one time**, counting everything anything you spawn spawns in turn. If a step wants more — a review panel, a set of verifiers, a fan-out over files — run them in batches of 4 and wait for each batch before starting the next. Never widen the fan-out to go faster; this environment serialises on the local env lock and the gradle daemon anyway, so extra threads cost contention and buy nothing. If a skill you invoke asks for a bigger panel, cap it at 4 and say so in your report.

The subagent prompt must carry:
1. **The invocation**: "Invoke the `sl-issue` skill (Skill tool, `skill: sl-issue`) with `<n>` *(plus `--skip-worktree` if the user passed it)* and follow it end to end."
2. **The no-interaction rule**: "You cannot reach the user. If you hit a requirement that is ambiguous in a way that changes *what* to build, do **not** guess and do **not** proceed — stop and return `BLOCKED:` followed by the specific question and the concrete options you'd offer. Resolve pure implementation choices yourself."
3. **Batch context** when it matters: "This is item `<i>` of `<N>`; item `<i-1>` (#`<prev>`) is <merged | open in PR #X and NOT merged, so your `origin/main` base does not contain it>." Call out explicitly when the previous item added a **Flyway migration** — the next item must not reuse that version number. Under `--keepGoing` `<N>` is the queue's **current** length, which grows as takeaways are filed; say "of `<N>` so far" rather than implying a fixed total.
4. **The report contract** — end your final message with: issue title + URL; PR URL; the requirements checklist with each row's ✅/❌ and evidence; verification verdict; whether an `sl-plan` plan of record was adopted (and what drifted if amended); confirmation the card moved to "In review"; the worktree root path and whether it was removed; and explicitly — **caveats, deferred/out-of-scope requirements, and follow-ups worth filing**, plus the **ops footprint** (`### Ops / rollout`): does this need a backend/UI/embed/infra **deploy**, does it add a **Flyway migration**, and which live integration configs must be **republished** afterwards.

### 4c. Report back to the user
Relay the run's outcome in the terminal — the subagent's report is **not** shown to the user, so surface it yourself: PR URL, the requirements table with ✅/❌, the verify verdict, the worktree path, the card's column, and **every caveat and follow-up, up front rather than buried**. Always call out the **ops footprint** (deploy / migration / configs to republish) — that's what turns a merged PR into a working change, and it's the easiest thing to lose in a batch. Then stop and let the user respond — questions, corrections, "change this before merging" — this is their interaction point.

**If the run came back `BLOCKED:`** — put the question to the user with `AskUserQuestion` (using the options the subagent proposed), post the answer back onto the GitHub issue as a comment so the ticket stays the source of truth (`gh issue comment <n> --repo Zangow/IntegrationService --body "Clarified scope: …"`), then **resume that same subagent** with `SendMessage` to its agent ID so it continues with its context intact — do not spawn a fresh one and pay for the whole context again.

**If the user wants changes** to the delivered work, send them to the same agent with `SendMessage` too; it still has the worktree, the branch, and the checklist.

**With `--keepGoing`:** still relay the run's outcome — the user reads it afterwards and it is the only record of what happened — but **do not stop**. Then file the run's takeaways as cards (see the `--keepGoing` section), report which ones you filed and where each landed in the queue, and go straight to 4d. A `BLOCKED:` run is **not** put to the user and **not** guessed at: file it and move on per "When an item can't close out cleanly".

### 4d. Offer merge + cleanup
**Without `--keepGoing`:** once the user is satisfied, offer it — never merge unprompted. (**With `--keepGoing`, skip straight to the close-out block at the end of this step.**) Check mergeability first:
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

**With `--keepGoing`:** don't offer — close the item out. Check mergeability first exactly as above; if it isn't clean, take the "can't close out cleanly" path instead. Otherwise run these in order, and report the result of each:

```bash
export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"

gh pr merge <pr> --repo Zangow/IntegrationService --merge   # if THIS fails, stop here — see "can't close out cleanly"
gh issue close <n> --repo Zangow/IntegrationService
"${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-move-issue-column.sh" Zangow/IntegrationService <n> "Done"
"${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/sl-worktree.sh" remove issue-<n>-<slug>
```

**Order matters**: merge before closing (a PR merged after its issue closes still works, but the board move reads the closed state), and merge before removing the worktree (the branch must be on the remote and merged). Never `--force` a worktree removal — if it has uncommitted changes the run left something behind, so leave it and say so. No `env-release` here: `remove` already releases the lock, and a bare `env-release` from the driver exits 1 because the lock owner is the *worktree* root, not yours.

If the merge succeeds but a later step fails, **that is not a failed item** — board moves and worktree cleanup are conveniences, not gates. Note it and carry on. A GitHub GraphQL rate limit (5,000/hr, shared) will take out board moves first; when you hit one, stop retrying, record which cards need their column set by hand, and keep working — REST calls still have quota.

### 4e. Ask before the next item
> **Ready for the next one?** — next up is `#<n>: <title>` (item `<i+1>` of `<N>`).

Offer *Start it* / *Skip it and go to the one after* / *Stop here*. On confirmation, go back to **4a** for that item. Never roll straight into the next item unprompted.

**With `--keepGoing`:** no gate. Print one line — `→ next: #<n> <title> (item <i+1> of <N>)`, where `<N>` is the **current** queue length including anything filed this item — and go straight to 4a. Stop only when the queue is exhausted or the user interrupts.

## 5. Final summary
When the queue is exhausted (or the user stops), print one table over every item: `#`, title, outcome (shipped / blocked / skipped / stopped), PR URL, merged?, worktree removed?, board column. Below it, list **every caveat and follow-up** collected across the runs, plus the **combined ops footprint** for the batch — what needs deploying, which migrations landed, and which live configs must be republished. Those are the easiest things to lose in a long batch, and they're usually the reason the next ticket exists.

**With `--keepGoing`, this summary is the whole interaction** — the user has not seen a single gate, so it carries the weight of all three skipped pauses. In addition to the above:

- Mark which rows were **filed by the batch** rather than asked for, and show the queue in the order it was actually worked, so an inserted critical is visible where it ran.
- A **takeaways table**: `#`, title, critical?, queue position (next / end / filed-only), and the item it came from.
- **Everything that did not close out cleanly**, in its own list, up front: blocked runs with their unanswered question, unmerged PRs with the reason, worktrees deliberately left on disk, and any card whose column needs setting by hand.
- **The one thing the user must decide now** — if the batch surfaced a decision only they can make (a deploy, an irreversible publish, an unanswered `BLOCKED:`), lead with it. Autonomy defers those decisions; it does not make them.

## Notes
- **This skill never writes feature code.** Every implementation decision belongs to the `sl-issue` subagent; this skill expands, filters, claims, dispatches, relays, and gates.
- **Serial by design.** `sl-issue` supports parallel authoring via worktrees, but a batch is a dependency chain far more often than not — especially Flyway version numbers, which collide silently when two branches off the same `main` each add one. One at a time, merged in between.
- **Fresh context per item is the point.** Each item gets its own subagent so requirements, file paths, and half-formed assumptions from item N never bleed into item N+1.
- **The three pauses are load-bearing**: the queue round up front (step 3), the results review (4c), and merge + next (4d/4e). Everything between them runs without stopping. **`--keepGoing` removes all three** — that is its entire purpose, and the final summary is what has to carry them.
- **`--keepGoing` removes the pauses, never the judgement.** It still refuses to merge an unclean PR, still refuses to answer a `BLOCKED:` question, and still refuses to work a card it would have dropped. If a run's own report says the work isn't right, the flag does not make it right.
- **`BLOCKED:` is resumed, not restarted** — `SendMessage` back to the same agent keeps the worktree, branch, and checklist alive.
- **Board and assignee updates are conveniences, not gates.** If a board move or assignee add fails (usually missing gh scopes — `gh auth refresh -s read:project,project`), surface it and keep going.
