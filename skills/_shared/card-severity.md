# Card severity — every proposed or filed card carries a severity AND its justification

**Every card a skill proposes, drafts, files, or splits off — an `sl-issues` takeaway, an
`sl-subtask` child, a "follow-up worth filing" in an `sl-issue` report — states a severity from the
fixed scale below AND one or two sentences justifying it.** A proposal without both is incomplete
and is **dropped by the driver, not guessed at** — treat a missing severity line like a missing title.

Skills point here with one line instead of restating it:

```
> **Card severity:** every proposed/filed card carries `Severity:` + `Why this severity:` per `_shared/card-severity.md`.
```

## The scale — exactly these four words

Judge by **consequence if left as-is**, not by how interesting it is. Same ladder as
`finding-disposition.md`, which decides what a run *fixes*; this file decides what a *card* says.

| Severity | Meaning |
|----------|---------|
| **Critical** | Data loss/corruption (incl. already-delivered S3 data), security or credential/PII exposure, breaks `main` or a deploy, a PROD outage or customer-visible delivery failure, or a card's own acceptance criteria are untrue. |
| **High** | A real defect a customer or operator hits on a normal path — wrong or missing records, a crash, a silently-swallowed failure, an alarm that stays dark. |
| **Medium** | Real but off the normal path, degraded rather than broken, a workaround exists, or the cost of leaving it is bounded. |
| **Low** | Style, naming, hygiene, hypotheticals, "we could also…", nice-to-haves with no measured impact. |

**When torn between two levels, pick the lower.** Escalating a maybe to justify a card is the
failure mode this rule exists to catch. For a self-review finding, `finding-disposition.md`'s
"ambiguous is Medium" applies first — a finding torn between High and Medium never becomes a card.

## The required block — in the card body AND in the terminal proposal

```markdown
**Severity:** <Critical | High | Medium | Low>
**Why this severity:** <1–2 sentences: the concrete consequence if left as-is, who hits it, and how often>
```

- **Name the consequence, not the finding.** "Every poll of `yelp-leads` in PROD delivers zero
  records and reports SUCCESS" justifies High; "the jq filter is wrong" does not.
- **Say who hits it and on what path** — normal path vs edge case is the High/Medium line.
- **Thin evidence drops a level** — "seen once in logs, not reproduced" is not High.
- **`Severity: High` with no `Why` counts as missing.** The driver does not infer a reason.

## Where it applies

| Producer | Where the block goes | Extra rule |
|----------|----------------------|------------|
| `sl-issues` takeaway (proposed at 4c, filed after approval) | the 4c proposal, and copied verbatim into the filed card body | Admitted **only** at Critical/High **plus** the `finding-disposition.md` exception it clears (1 not that card's code / 2 needs a human decision or ops action / 3 blocked). Missing any of the three → dropped. |
| `sl-issue` / `sl-ship` / `sl-verify` "follow-ups worth filing" | in each follow-up in the run report — that is the proposal `sl-issues` 4c relays | Same admission rule as above. |
| `sl-subtask` children | each child's body, under the `Surface / Repo / Depends on / Blocks` header | Any of the four words. Inherit the parent's severity unless the child's consequence differs, and say why; a parent without one → judge the child on its own. |
