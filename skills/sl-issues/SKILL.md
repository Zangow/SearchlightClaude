---
name: sl-issues
description: "Batch front door over `sl-issue` — takes one or more Searchlight IntegrationService issue numbers/URLs (space-delimited, e.g. `/sl-issues 171 173 186`), expands each into its native GitHub sub-issues (recursively, parent-first), drops anything CLOSED or already ASSIGNED (to anyone, including you — that means it's already been picked up), and works the remaining queue ONE AT A TIME. Per item it assigns the issue to you, dispatches a fresh context-isolated subagent to run `/sl-issue` on it, reports that run's results (PR, requirements, caveats, follow-ups) back for you to interact with, then offers to merge the PR and remove the worktree before asking whether to start the next one. This skill is always interactive — there is no unattended mode: nothing merges to `main` without a human reading the run's report and approving the merge. Use when asked to \"work issues 1 2 3\", \"run this batch of Searchlight tickets\", \"do issue X and its subtasks\", or when handed several issue numbers to implement end-to-end."
effort: medium
---

# sl-issues — batch queue over `sl-issue` (Searchlight)

> **Repo paths use `$SL_BASE_PATH`** — resolve it per `_shared/base-path.md`.

> **Waiting:** follows `_shared/waiting.md` — never end a turn on a pending wait (a child, a `SendMessage` reply); every wait is bounded, and what outlives its bound is stopped along with its orphans.

This skill **does not implement anything itself**. It is a queue driver: it expands the issues you name into a full work list (each issue **plus its sub-issues**), then walks that list one item at a time, handing each item to a **fresh subagent that runs `/sl-issue`** in its own context. You stay in the loop between items — you see each run's results, decide whether to merge, and say when to start the next.

**Why one at a time, in order:** each `sl-issue` run cuts its worktree branch off freshly-fetched `origin/main`. Merging item N before starting item N+1 is what makes N+1's base contain N's work — which matters constantly here, because a parent and its sub-issues usually touch the same config, the same Flyway migration chain, or the same acceptance-test class.

## Inputs
Space-delimited issue numbers and/or URLs — `/sl-issues 171`, `/sl-issues 173 186 187`, `/sl-issues 171 https://github.com/Zangow/IntegrationService/issues/173`. A bare number (with or without `#`) **defaults to `Zangow/IntegrationService`**. If no issue was given, ask for it.

**Flags:**
- `--skip-worktree` — passed straight through to each `sl-issue` run.

**Concurrency is capped at 4 subagents in flight under each item's child, flag or no flag** — see 4b.

## Filing takeaways — the bar is high, and it is not the default

This skill is **always interactive**: it pauses three times per item and you decide. There is no autonomous mode and no flag that removes the pauses — work does not reach `main` in this repo without a human looking at it. If you want a run to keep going unattended, that is a deliberate change to this skill, not a flag.

So a takeaway is never filed behind your back. The driver **proposes** it at 4c; you say file it or drop it.

**Default: propose nothing.** An `sl-issue` run is supposed to *finish* its card, not spawn the next three. Per `_shared/finding-disposition.md`, the child run has already fixed everything Critical/High in its own diff and dropped everything Medium/Low — so **most runs should have nothing to file.** If a batch is producing a card per item, that is the bug, not the feature. (#248 → #268 → fifteen open follow-ups is what this rule exists to prevent.)

> **Card severity:** every proposed/filed card carries `Severity:` + `Why this severity:` per `_shared/card-severity.md`. A takeaway is admitted **only** at Critical/High **and** with the `finding-disposition.md` exception it clears (not that card's code / needs a human decision or ops action / blocked). Missing any of the three → drop it; don't infer. Anything vague ("we should look into X", "consider extracting Y", "add more tests") is dropped too. Dropped means *gone* — not a card, not a queue line, not carried into the next prompt.

**Before filing, check it against the cards this batch has already filed.** If it is the same substance as an existing one, comment on that card instead — two runs noticing the same missing index must not produce two cards.

```bash
REPO=Zangow/IntegrationService

# 1. create the card
URL=$(gh issue create --repo "$REPO" \
  --title "<takeaway title>" \
  --body "$(cat <<'EOF'
Filed from the `/sl-issues` run on #<item>, with the user's approval.

**Severity:** Critical|High
**Why this severity:** <copied verbatim from the run's proposal>
**Why it wasn't fixed in-run:** <exception 1, 2, or 3>

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

### A filed card is not queue work

Filing a card and *working* it are separate decisions, and only you make the second one. A takeaway you approve is filed and listed — it does **not** get inserted into this batch's queue. If one is critical enough that later items would be built on top of the problem (data loss, a security exposure, a broken `main`, or something that invalidates a card already shipped in this batch), **say so when you propose it** and ask whether to work it next; if the answer is yes, it enters the queue at 4a like any other item. Everything else is a card for later.

### Two signals worth stopping for

The queue is fixed once you start it, so it can't run away — but two patterns still mean *stop and report* rather than push on to the next item:

- **Filing rate:** if **3 consecutive items each produce a card**, stop before starting the next. Either the runs are ignoring `_shared/finding-disposition.md`, or something systemic is wrong with `main` — both are worse than a paused batch.
- **Circuit breaker:** after **3 consecutive items that fail to close out cleanly**, stop and report. Usually a bad merge on `main` that every later base now carries, in which case continuing just burns the queue producing one critical finding per item.

Track, in-session, the list of cards this batch filed — that list is the marker, not a label (don't invent one; `takeaway` does not exist in this repo and `gh` hard-fails on an unknown label, which would abort the create). Report everything filed, and either signal if you hit it, in the final summary.

### When an item can't close out cleanly

In each of these cases: **do not merge, leave the worktree in place, and report it to the user** — with a proposed takeaway card recording exactly what happened, if it clears the bar above. If they choose to move on to the next item, carry the fact into the next subagent's prompt, because its base won't contain this item's work.

- The run returned **`BLOCKED:`** — file the blocking question and the options it proposed, verbatim. **Don't answer it and don't guess** — put it to the user (4c).
- The run **produced no PR** — it crashed, timed out, or returned a report with no PR URL. There is nothing to merge; don't reach for a `<pr>` that doesn't exist. A run that ended **without any report** is not written off yet — resume or sweep it first (4c, "ended without a report").
- The run returned **`SHIP-FAILED:`** — its ship agent hit `sl-verify`'s 1-round repair cap without going green. File the verifier findings verbatim as the takeaway card. **Don't re-dispatch the item to burn another round**: a round that didn't converge means the diagnosis is wrong, and a fresh full run pays for the whole issue again to reach the same wall. It needs a human or a targeted follow-up card, not a retry.
- The run returned **`SHIP-BLOCKED: review-unavailable`** — the built-in `code-review` failed to launch in **both** forms (on the tree, then on the PR — `sl-ship` step 1's fallback ladder), so the item is code-complete but **unreviewed**. This is the one case that **stops the batch rather than moving on**: if the reviewer is unavailable for one item it is almost certainly unavailable for every item behind it, so continuing would produce a queue of code-complete, unreviewed branches. Halt the run, report both failures verbatim with the branch and worktree path, and ask the user to run `/code-review medium --fix` on that branch themselves. When they confirm it's done, **resume the `sl-issue` child via `SendMessage`** (the same mechanism the `BLOCKED:` path uses) with: *"The step-1 review has been run by the user on `<branch>` (`code-review medium --fix`, `<when>`). Re-dispatch your ship agent with that line in its brief so it skips step 1 and starts at step 2, then finish your normal post-ship duties."* Resume the child, not the ship agent directly — the driver never held the ship brief (`SL_BASE_PATH`/`SL_REAL_BASE`, checklist path, base ref), and `sl-issue` still owns the board move and the report format. And never re-dispatch without that line: it just hits the same failure again.
- The PR is **not cleanly mergeable** (conflicts, `mergeStateStatus` not clean).
- **`gh pr merge` itself fails** after a clean pre-check — branch protection, or a push that landed in between. Stop the close-out block there: do **not** close the issue (the close is also the card's move to "Done").
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
One subagent per item, **`subagent_type: sl-core-worker`** (opus @ **high** effort by definition — authoring is a core role, and the Agent tool has no `effort` param, so a bare `general-purpose` + `model: opus` dispatch would silently inherit the session default), and **do not end your turn until its result arrives** — every dispatch is async, so wait per `_shared/waiting.md` rule B; you need the result before continuing, and the queue is deliberately serial. Wait for every `SendMessage` reply to a child the same way. Nothing from the previous item leaks into this one.

**Concurrency budget — cap the fan-out inside the item.** The queue being serial bounds *your* dispatches to one at a time, but it does **not** bound the child's: `sl-issue` calls `sl-ship`, which runs a backgrounded `code-review --fix` pass and `sl-verify`, each of which can fan out again. Nested panels multiply, and a single item has been seen running dozens of threads at once — which mostly buys contention, not throughput. Two gradle builds in one worktree alone fake a ~60-class failure.

So the prompt must impose a hard ceiling: **at most 4 subagents in flight at any moment under the child, counting every nested level** (the child itself is not counted). It is the same cap `agents/sl-core-worker.md` carries, repeated in the prompt so it survives a dispatch to any other agent type. Beyond that, run them in waves rather than widening. Put it in the prompt verbatim:

> **Concurrency limit: at most 4 subagents running at any one time**, counting everything anything you spawn spawns in turn. If a step wants more — a review panel, a set of verifiers, a fan-out over files — run them in batches of 4 and wait for each batch before starting the next. An `sl-core-worker` you dispatch counts against the 4 — pass it the remainder as its cap. Never widen the fan-out to go faster; this environment serialises on the local env lock and the gradle daemon anyway, so extra threads cost contention and buy nothing. If a skill you invoke asks for a bigger panel, cap it at 4 and say so in your report.

The subagent prompt must carry:
1. **The invocation**: "Invoke the `sl-issue` skill (Skill tool, `skill: sl-issue`) with `<n>` *(plus `--skip-worktree` if the user passed it)* and follow it end to end."
2. **The no-interaction rule**: "You cannot reach the user. If you hit a requirement that is ambiguous in a way that changes *what* to build, do **not** guess and do **not** proceed — stop and return `BLOCKED:` followed by the specific question and the concrete options you'd offer. Resolve pure implementation choices yourself."
3. **Batch context** when it matters: "This is item `<i>` of `<N>`; item `<i-1>` (#`<prev>`) is <merged | open in PR #X and NOT merged, so your `origin/main` base does not contain it>." Call out explicitly when the previous item added a **Flyway migration** — the next item must not reuse that version number.
4. **The report contract** — end your final message with: issue title + URL; PR URL; the requirements checklist with each row's ✅/❌ and evidence; verification verdict; whether an `sl-plan` plan of record was adopted (and what drifted if amended); confirmation the card moved to "In review"; the worktree root path and whether it was removed; and explicitly — **caveats, deferred/out-of-scope requirements, and follow-ups worth filing** (each with `Severity:` + `Why this severity:` per `_shared/card-severity.md`), plus the **ops footprint** (`### Ops / rollout`): does this need a backend/UI/embed/infra **deploy**, does it add a **Flyway migration**, and which live integration configs must be **republished** afterwards.

### 4c. Report back to the user
Relay the run's outcome in the terminal — the subagent's report is **not** shown to the user, so surface it yourself: PR URL, the requirements table with ✅/❌, the verify verdict, the worktree path, the card's column, and **every caveat and follow-up, up front rather than buried**. Always call out the **ops footprint** (deploy / migration / configs to republish) — that's what turns a merged PR into a working change, and it's the easiest thing to lose in a batch. Then stop and let the user respond — questions, corrections, "change this before merging" — this is their interaction point.

**If the run came back `BLOCKED:`** — put the question to the user with `AskUserQuestion` (using the options the subagent proposed), post the answer back onto the GitHub issue as a comment so the ticket stays the source of truth (`gh issue comment <n> --repo Zangow/IntegrationService --body "Clarified scope: …"`), then **resume that same subagent** with `SendMessage` to its agent ID so it continues with its context intact — do not spawn a fresh one and pay for the whole context again.

**If the run ended without a report** — the completion notice says it "has not reported yet" or ended without delivering a report through `SubagentHandback`, or the result carries no PR URL and none of `BLOCKED:` / `SHIP-FAILED:` / `SHIP-BLOCKED:` — the child may have ended its turn holding a wait while its work is still running. Never drop it silently:
1. **Look for the result first.** Find the branch (`git -C "$SL_BASE_PATH/<repo>" ls-remote --heads origin '*issue-<n>-*'` — `IntegrationService`, or `.claude` on a skills card) and run `gh pr list --repo <owner>/<repo> --head <branch> --state all`. A PR there is the result: still ask for the report (step 2), and if none comes, relay the PR marked "report not delivered — requirements table missing".
2. **Resume it once.** `SendMessage` the child: *"You ended without a report. Finish or stop every wait you still hold per `_shared/waiting.md` — if your ship agent ended without a report, check `gh pr list --head <branch>` rather than re-dispatching it — then send your report per the report contract."* Wait for the reply per rule B: ~20 min, extended in 540 s slices only while a liveness signal moves (`_shared/gradle-busy.sh <worktree>/IntegrationService` exits 4, or the branch's `HEAD` / `origin/<branch>` changed), hard cap 60 min. One such resume per item.
3. **Still nothing → sweep, then report.** `TaskStop` the child, then every running subagent started after this item's dispatch that you did not dispatch — `TaskStop` does not stop an agent's children, so each orphan is stopped by its own id. Then inventory what it left: the worktree (`ls -d "${SL_REAL_BASE:-$SL_BASE_PATH}/.sl-worktrees/issue-<n>-"*`, its `git status --short` and unpushed commits), the branch (pushed? PR?), and the claim (still assigned to you, card in "In progress"). Report all three here as an item that did not close out cleanly: leave the worktree and branch in place, and offer to release the claim (`gh issue edit <n> --repo Zangow/IntegrationService --remove-assignee @me`) — while it stays assigned, a later `/sl-issues` run drops it as already picked up.

**Never end the item, or dispatch a fresh child for it, while the old child or its orphans still run** — two children over one worktree corrupt each other.

**If the user wants changes** to the delivered work, send them to the same agent with `SendMessage` too; it still has the worktree, the branch, and the checklist. That includes *"fix this before merging"* on something they spotted in the diff — it is the same mechanism, and it goes back to the agent that owns the branch rather than becoming an edit in your context. If the change is code, the agent re-runs `./gradlew check` and reports back before you return to 4d; it does **not** re-run the whole ship pipeline.

### 4d. Offer merge + cleanup
Once the user is satisfied, offer it — **never merge unprompted.** Check mergeability first:
```bash
gh pr view <pr> --repo Zangow/IntegrationService \
  --json number,title,mergeable,mergeStateStatus,statusCheckRollup,headRefName
```
Report anything not cleanly mergeable (conflicts, failing checks) and **do not merge** it without an explicit override. Note that this repo has **no GitHub Actions workflows** — an empty `statusCheckRollup` is expected, not a red flag; the quality gate is the locally-run `./gradlew check` that `sl-ship` records on the PR.

Offer with one `AskUserQuestion` (`multiSelect: true`): *Merge the PR* / *Remove the worktree* / *Close the issue* / *Leave everything as is*.

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
  ```
  That close **is** the move to "Done" — never follow it with `sl-move-issue-column.sh … "Done"`. The Searchlight Integration Service board's built-in workflows move a closed issue's card to "Done" (*Item closed*) and close an issue whose card lands in "Done" (*Auto-close issue*), so closing and moving to "Done" are one action. The close is a REST call — no GraphQL cost. Conversely, never move a card to "Done" while meaning to leave the issue open; it will be closed.

**Deploying is not part of this skill.** Merging lands the code on `main`; getting it into QA/PROD is `/sl-deploy`, and republishing affected integration configs is a separate ops step. Say which items in the batch need one, and let the user decide when — batching several merges and deploying once at the end is usually the right call.

**If the user declines the merge**, say plainly what it costs: the next item branches off `origin/main` without this work. Carry that into the next subagent's prompt (point 3 above) so it knows its base is missing the parent's code.

A GitHub GraphQL rate limit (5,000/hr, shared) will take out board moves first; when you hit one, stop retrying, record which cards need their column set by hand, and keep working — REST calls still have quota. A failed board move or worktree removal after a successful merge is **not** a failed item; note it and carry on.

### 4e. Ask before the next item
> **Ready for the next one?** — next up is `#<n>: <title>` (item `<i+1>` of `<N>`).

Offer *Start it* / *Skip it and go to the one after* / *Stop here*. On confirmation, go back to **4a** for that item. Never roll straight into the next item unprompted.

## 5. Final summary
When the queue is exhausted (or the user stops), print one table over every item: `#`, title, outcome (shipped / blocked / skipped / stopped), PR URL, merged?, worktree removed?, board column. Below it, list **every caveat and follow-up** collected across the runs, plus the **combined ops footprint** for the batch — what needs deploying, which migrations landed, and which live configs must be republished. Those are the easiest things to lose in a long batch, and they're usually the reason the next ticket exists.

Also, in their own list and up front:

- **Everything that did not close out cleanly**: blocked runs with their unanswered question, unmerged PRs with the reason, worktrees deliberately left on disk, and any card whose column needs setting by hand.
- **The one thing the user must decide now** — if the batch surfaced a decision only they can make (a deploy, an irreversible publish, an unanswered `BLOCKED:`), lead with it.
- **Cards filed during the batch**, with the item each came from.

## Notes
- **This skill never writes feature code.** Every implementation decision belongs to the `sl-issue` subagent; this skill expands, filters, claims, dispatches, relays, and gates.
- **Serial by design.** `sl-issue` supports parallel authoring via worktrees, but a batch is a dependency chain far more often than not — especially Flyway version numbers, which collide silently when two branches off the same `main` each add one. One at a time, merged in between.
- **Fresh context per item is the point.** Each item gets its own subagent so requirements, file paths, and half-formed assumptions from item N never bleed into item N+1.
- **The three pauses are load-bearing and non-optional**: the queue round up front (step 3), the results review (4c), and merge + next (4d/4e). Everything between them runs without stopping. They are where a wrong-but-plausible run gets caught, and they are the reason this skill needs no post-PR review of its own — the human at 4c/4d *is* that review. An autonomous mode was supported and **removed**: it deleted exactly those three checks, which meant code reached `main` on the strength of a run's own verification and nothing else. Don't reintroduce it as a flag.
- **`BLOCKED:` is resumed, not restarted** — `SendMessage` back to the same agent keeps the worktree, branch, and checklist alive.
- **Board and assignee updates are conveniences, not gates.** If a board move or assignee add fails (usually missing gh scopes — `gh auth refresh -s read:project,project`), surface it and keep going.
