# `review-gate.md` — the plan-time review gate: roster, adjudication, one delta round, then a human

The one procedure every plan-time review panel follows, stated once. It applies to:

| Caller | Gate |
|--------|------|
| `sl-plan` step 5 | the plan, before it lands on the card |
| `sl-subtask` step 6 | the breakdown, before any child is filed |

**The caller owns** the lens each reviewer gets (the question it asks), anything each reviewer is
handed beyond the basics in step 1, and where the verdict is recorded. **This file owns** the roster
size, the escalation triggers, and everything from dispatch to the final verdict. Why the panel is
mixed, isolated and nominate-only, and why an Opus pass decides, is `model-orchestration.md` "How to
run a review panel" — not restated here.

## Roster — scaled to blast radius

- **Default:** 1× **`sl-depth-reviewer`** + 1× **`sl-panel-reviewer`**, each dispatched **by type**
  so its pinned model and effort apply.
- **Escalated:** 1× `sl-depth-reviewer` + **2×** `sl-panel-reviewer`, each on a distinct lens, when
  the artifact touches any of: a Flyway migration, already-delivered S3 data
  (remap/purge/redaction/versioning), a published contract or standard schema, credentials/PII, or
  IAM. Those are the changes that are expensive to unwind.

Never below the default — the `sl-panel-reviewer` is the panel's non-Opus voice
(`model-orchestration.md` step 2).

## The five steps

1. **Dispatch the roster in one message, concurrently.** Each reviewer gets the issue URL, the
   step-2 grounding, the artifact text (plan or breakdown), and its lens — never your reasoning for
   the artifact. Ask each to tag every finding **`BLOCKER`** (would make a checklist row untrue, or
   break `main`, a deploy or live data if built as written) or **`CONCERN`** (anything else), anchored
   to a `file:line`, a plan step or a card number. An unanchored finding is a CONCERN at most.
2. **Adjudicate every BLOCKER** — inline or via `sl-adjudicator`, per `model-orchestration.md` step
   5. Each is **confirmed**, **demoted** to a CONCERN, or **dropped**. An inline demote or drop cites
   the anchor you opened to check it; if you are torn, the BLOCKER stands. **Only confirmed BLOCKERs
   change the artifact.**
3. **Keep a CONCERN ledger.** Every CONCERN — raised or demoted — gets a one-line disposition
   (addressed, or consciously accepted and why) where the caller records the verdict. It is never
   re-litigated.
4. **One re-review round, on the delta only — and only if step 2 confirmed a BLOCKER.** Re-dispatch
   the `sl-depth-reviewer` alone with the amended artifact, the confirmed BLOCKERs and the ledger (a
   fresh agent has no memory; without the ledger it re-raises settled decisions). Adjudicate its
   BLOCKERs as in step 2.
5. **Still a confirmed BLOCKER after round 2 → `AskUserQuestion`.** Offer: split the work (`/sl-subtask
   <n>` from `sl-plan`; a two-level split from `sl-subtask`), accept the remaining BLOCKERs as
   documented CONCERNs and proceed, narrow the card's scope, or abandon. **Never dispatch a round 3
   on your own judgement.**

## Reference it from a skill like

```
> **Review gate:** roster → dispatch → adjudicate → one delta round → ask, per `_shared/review-gate.md`.
```
