# Finding disposition — fix it now, or drop it

Applies to **every self-review finding a run generates about its own work**: `simplify`,
`code-review` on the PR, `sl-verify` caveats, and anything a review panel nominates during
`sl-plan` / `sl-subtask` / `sl-issue` / `sl-ship`.

## The rule

> **Critical and High → fix it on this card, now, before the PR.
> Medium and Low → drop it.**

A card is finished when its own acceptance criteria are met and nothing critical or high is
outstanding. It is *not* finished only once every observation anyone made about the code has
its own ticket. Spawning follow-up cards is the failure mode this policy exists to stop: it is
how a single ticket turns into an open-ended tree that never closes.

## Severity ladder

Judge severity by **consequence if shipped as-is**, not by how interesting the finding is.

| | Test | Disposition |
|---|---|---|
| **Critical** | Data loss/corruption, security exposure, breaks `main` or a deploy, or makes this card's own acceptance criteria untrue. | **Fix now.** Re-verify, then PR. |
| **High** | A real defect a user or operator would hit on a normal path — wrong results, a crash, a silently-swallowed failure, an unhandled error case in code this card touched. | **Fix now.** Re-verify, then PR. |
| **Medium** | Real but tolerable — a slow path nobody is hitting yet, a missing edge-case test, an awkward abstraction, a pre-existing wart the diff brushed against. | **Drop**, unless it's a genuinely small fix in code already open in this diff — in which case just do it silently. |
| **Low** | Style, naming, hypotheticals, "we could also…", cleanliness of code this card didn't change. | **Drop.** Do not mention it beyond one line in the run report, if that. |

**When severity is ambiguous, it is Medium.** Escalating a maybe to High to justify fixing it
is the same trap in a different direction — it grows the diff past what the card asked for.

## Dropping is a real outcome

"Drop" means: don't fix it, don't file a card, don't add it to a PR follow-ups list, don't
carry it into the next run's prompt. At most, one line in the run's terminal report. The
information is cheap to rediscover — the next run that touches that code will notice it again.

## The only things that may become a new card

A finding graduates to a card **only** when it is Critical or High **and** one of these is true:

1. **It's not this card's code.** The defect is in an unrelated subsystem the diff didn't
   touch, and fixing it would mean a second, unreviewable change riding along in this PR.
2. **It needs a human decision.** A product/scope question, a contract change with an external
   consumer, a Flyway migration, or an ops action (a deploy, a live-config republish, a
   published canonical-schema change).
3. **It's blocked.** A missing credential, an unavailable environment, a third party.

Everything else that is Critical or High gets **fixed in this run**. Everything that is Medium
or Low gets **dropped**, whether or not it meets 1–3.

Before filing under 1–3, say the severity and which exception applies, in the card body. If
you can't name one, you don't file.

## Scope guard

Fixing a Critical/High in-run does **not** license a refactor. Make the smallest change that
removes the consequence, keep it inside the card's requirement where you can, and re-run
verification. If the smallest honest fix is genuinely large or would rewrite a subsystem, that
is exception 2 — surface it to the user rather than expanding the diff unilaterally.
