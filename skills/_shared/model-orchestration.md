# Model & effort orchestration policy — Searchlight

**Single source of truth** for how the `sl-*` skills assign Claude **models** and **reasoning
effort** across the `plan → author → review/verify` roles. Skills reference this file rather than
restating the policy, so the suite stays consistent and this is the one place to edit when the
roster changes.

## The principle

Spend **capability** where per-shot quality dominates, and **independent coverage** where breadth
dominates. Structure — iteration, verification, isolated perspectives — approximates a stronger
single-shot model at a fraction of the cost, but only for the roles where the answer comes from
observation rather than deliberation.

- **Core roles — plan, author, adjudicate → Opus @ high.** A wrong call here is expensive and
  nothing downstream catches a bad *design*. Don't cheap out.
- **Verification → Sonnet @ medium.** It's grounded in **real execution**: the service either
  returned the right thing or it didn't. Context isolation — a verifier that didn't author the
  code — is what removes rationalization bias, and that's free. The model tier adds little on top.
- **Cheap decorrelated lenses → Sonnet.** A second, *different* model catches classes of issue no
  amount of Opus repetition would, because every Opus instance shares the same blind spots.

## Model and effort are two axes, not one

Model buys *capability per shot*; effort buys *how long the model deliberates before answering*. A
role can want one without the other — verification wants a competent model but almost no
deliberation (the test run already decided), while adjudication wants both.

**Scale effort to how much the answer depends on deliberation, not to how much it matters.** A hard
gate matters enormously and still doesn't need high effort if what decides it is a request returning
a 200. Conversely a subtle auth question can matter little in isolation and still need high effort,
because nothing but reasoning will surface it. Ask: *would thinking longer change this answer?* If
it comes from a tool, a test run, or a fixed rubric — it wouldn't.

## Where effort is actually enforced

**Effort cannot be set on an Agent-tool call.** The Agent tool takes a `model:` param but **no
effort param**, so a skill that merely *writes* "dispatch this at medium effort" changes nothing.
Effort is pinned in exactly three places:

1. **Agent definitions** — `.claude/agents/<name>.md` frontmatter (`effort:` + `model:`). This is
   why the table below names a **dispatch type** rather than a bare model: the agent file is the
   only thing that makes the effort real.
2. **The session default** — `effortLevel` in settings, or `claude --effort <level>`. Governs the
   main thread, where the *core* roles run — so it should sit where those roles need it.
3. **Workflow scripts** — `agent(prompt, {effort: 'low'})`.

**The `model:` param still overrides the definition per call.** `subagent_type: sl-verify-runner`
+ `model: opus` gives an Opus verifier that still runs at the runner's medium effort — the right
shape for a contract, persistence, or auth change, and the reason the runner can default cheap
without losing the escalation path.

## Quick reference

| Role | Model | Effort | Dispatch as |
|------|-------|--------|-------------|
| Plan / architect | **Opus** | **high** | main thread (or `Plan` agent, then own the result) |
| Author / implement | **Opus** | **high** | main thread |
| Adjudicate panel findings | **Opus** | **high** | `sl-adjudicator` |
| Verify (behaviour + requirements) | **Sonnet**, → Opus for contract / persistence / auth / requirements gates | **medium** | `sl-verify-runner` |
| Ground the plan in real files | inherit | inherit | `Explore` |
| Review panel — depth lens | **Opus** | **high** | `general-purpose` + `model: opus` |
| Review panel — breadth lenses | **Sonnet** | inherit | `general-purpose` + `model: sonnet` |
| Mechanical checks (build/test/lint) | — | — | **inline, main thread** — an exit code has no authoring bias |

## Notes

- **Model names track tiers, not fixed ids.** "Opus" = the tier we default to for core work,
  "Sonnet" = the cheaper tier used to widen coverage. Update **this file** when the roster changes.
- **Proportionality.** A one-line change doesn't need a panel. Scale to blast radius: trivial →
  a single verifier; contract/persistence/auth → escalate the model and add a second lens.
- **Mechanical skills pin `model: sonnet` in their own frontmatter** instead of following this
  policy — `sl-start-env`, `sl-start-embed`, `sl-create-integration`. Nothing in them takes a
  judgment a stronger tier would make differently. **`sl-deploy` deliberately stays on the session
  model**: it is just as mechanical, but it ships production, and the saving on a handful of short
  runs doesn't justify a cheaper tier misreading a deploy gate.
- **The agent definitions this policy depends on** live in `.claude/agents/`: `sl-verify-runner`
  (sonnet/medium), `sl-adjudicator` (opus/high). Changing a role's effort means editing that file —
  editing this doc alone does nothing.
- **Applies to:** `sl-issue`, `sl-issues`, `sl-ship`, `sl-verify`, `sl-plan`, `sl-subtask`.
