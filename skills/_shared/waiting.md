# Waiting — never end a turn on a pending wait

**Why:** a subagent's report *is* its return value. A turn that ends while a background Bash, a
Monitor, an async Agent or a forked Skill is still pending returns nothing useful: the dispatcher
sees `completed` + "has not reported yet" and is not reliably resumed. The Driftwise pipeline lost a
whole ship that way (DriftwisePortal#1877/#1894) — the ship agent pushed, then ended on background
`sleep` waits with no PR, and its orphaned build kept running while a second one started over the
same tree.

Skills point here with one line instead of restating it:

```
> **Waiting:** follows `_shared/waiting.md` — never end a turn on a pending wait; every wait is bounded.
```

## Harness facts

- **Every Agent dispatch is async.** The Agent tool has no `run_in_background` parameter; it returns
  "Async agent launched" at once, and the child's report arrives attached to your **next foreground
  tool result**. So "dispatch in the foreground" means: *you do not end your turn until the result
  has arrived.* A background Bash completion arrives the same way.
- A foreground Bash call that outlives its `timeout` (default 120000 ms) or is interrupted is
  **moved to the background, not killed.** Poll it or `TaskStop` it; never re-run it alongside.
- A bare `sleep N` with N ≥ 25 as the first command segment is refused; a `for … sleep 15; done`
  loop is allowed.
- **`TaskStop` on an agent does not stop that agent's own children.** Stop each orphan by its id.

## Rules

**A — Nothing you are waiting on may outlive your turn.** Waits are: background Bash, Monitor,
async Agent dispatches, SendMessage replies, and forked Skills (`code-review --fix`). Before your
report, every one of them has finished and been read, or has been stopped (`TaskStop`) and is named
in the report as stopped. **Then** deliver the report — through `SubagentHandback` where that tool
exists (plain final text is not delivered when it does), otherwise as your final message. Exempt:
long-lived *services* nobody is waiting on — `sl-start-env`'s `./gradlew bootRun` and `npm run dev`,
`sl-start-embed`'s server. They are the environment, not a wait; name them in the report.

**B — Wait in the foreground, with an explicit bound.**
- **A process, ≤ ~9 min:** foreground Bash with `timeout: 600000`.
- **A process, longer** (a deploy script, the AT pack, a full `./gradlew check`): start it **once**
  in the background through an rc wrapper, then poll in bounded foreground slices until its `rc`
  file is non-empty. Shell variables do not survive between Bash calls, so make a fresh directory
  first and write its path **literally** into every later call:
  ```bash
  mktemp -d                                                        # call 1 — prints e.g. /var/folders/…/tmp.Ab12
  ( <cmd> >/var/folders/…/tmp.Ab12/log 2>&1; echo $? >/var/folders/…/tmp.Ab12/rc )   # call 2, run_in_background: true — ONCE
  D=/var/folders/…/tmp.Ab12; for i in $(seq 36); do [ -s "$D/rc" ] && break; sleep 15; done; cat "$D/rc" 2>/dev/null; tail -40 "$D/log"   # call 3…
  ```
  Each slice is ≤540 s with `timeout: 600000`; re-issue it until `rc` exists. The `rc` file is also
  the exit code of **the command** — a backgrounded `<cmd>; tail log` reports `tail`'s exit code, not
  the deploy's. Never a bare `sleep N`, never a chain of blind sleeps.
- **A notification-delivered result** (an Agent, a SendMessage reply, a forked Skill) has no
  condition Bash can test. Wait with condition-less bounded slices —
  `for i in $(seq 36); do sleep 15; done` (`timeout: 600000`), optionally breaking early on a proxy
  (`gh pr list --head <branch>`, a file the child writes) — re-issued until the result is attached
  or the caller's stated bound passes. Past the bound: `TaskStop` it (and its orphans) and take the
  caller's fallback. Never end the turn to wait, and never hand the wait to a Monitor.
- Once the result lands, `TaskStop` any poll loop of yours still running.

**C — Several subagents at once** = several Agent calls in one message, then Rule B slices until
every result is in — within the caller's concurrency cap.

**D — One Gradle run per checkout.** Two Gradle runs in the same IntegrationService checkout fake a
false failure (~60 classes of "Could not write XML test results", plus unrelated
`PartnerS3IngestionE2EIT` failures). Before `./gradlew check`/`test`, make sure no other agent is
running Gradle in that tree (`pgrep -fl 'gradlew|GradleWrapperMain'` and check the cwd); if one is,
wait for it per Rule B. **Never kill a build you cannot prove you started.** If you see that
signature anyway, re-run on a quiet tree before calling the change broken.
