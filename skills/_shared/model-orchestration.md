# Model orchestration policy — which Claude model runs which role (Searchlight)

**Single source of truth** for how the `sl-*` skills assign Claude **models** and **reasoning
effort** across the `plan → author → review/verify` roles. Skills reference this file instead of
restating the policy, so the suite stays consistent and this is the one place to edit when the
roster changes.

## The roster, and why this exists

| Tier | Current model | Role here |
|------|---------------|-----------|
| `opus` | **Opus 5.5** | The default for core work — plan, author, adjudicate — and the depth lens on a review panel. |
| `sonnet` | **Sonnet 5** | The mid tier: breadth lenses on a panel, execution-grounded verification, and the mechanical skills. |
| `haiku` | **Haiku 4.5** | The small, fast tier. No role in this policy uses it. |
| `fable` | **Fable 5.1** | The top tier. Reaching for it is a per-task cost call, made by pinning `model: fable` on a specific agent; no role here defaults to it. |

Skills and agents name the **tier alias** (`opus`, `sonnet`, …), never a model id, and every other
file says "Opus" or "Sonnet" — so a roster change is an edit to this table only.

The policy gets top-tier *results* from Opus + Sonnet without paying for the top tier on every
call: spend capability where per-shot quality dominates, and independent coverage where coverage
dominates.

- **Core roles — plan, author, adjudicate → Opus.** Per-shot capability matters most here and a
  wrong call is expensive; nothing downstream catches a bad *design*. Sonnet on a core role is a
  deliberate cost/latency trade, never a quality win.
- **Review → a fresh-thread panel, mixed Opus + Sonnet.** Two separate levers combine:
  1. **Context isolation** (the big, near-free win): a reviewer that did **not** author the change,
     reading it cold, doesn't rationalize the author's choices. Isolation — not model choice — is
     what removes author bias.
  2. **Model diversity** (additive): every Opus instance shares the same blind spots; a Sonnet lens
     catches classes of issue no amount of Opus repetition would, and is cheap enough to run
     alongside. It pays off most for **static review** (plans, breakdowns, diffs, configs).
- **Verification → Sonnet, escalated to Opus for hard gates.** Verification is grounded in **real
  execution**: the service either returned the right thing or it didn't. The signal comes from the
  run, not the tier, so the default is one Sonnet `sl-verify-runner` (see "Verification panel").

## How to run a review panel

1. **Isolate.** Every reviewer is a fresh Agent-tool subagent that did **not** author the work.
   Hand it the artifact (plan, breakdown, diff) + the plain-English requirement — **never** your
   authoring reasoning.
2. **Diversify two ways at once:**
   - **Lens** — give each reviewer a distinct angle (correctness · spec-conformance · security ·
     edge-cases). Diverse lenses add more coverage than a duplicate reviewer.
   - **Model** — one **`sl-depth-reviewer`** (Opus, depth) **+ 1–2 `sl-panel-reviewer`** (Sonnet,
     breadth + decorrelated errors), scaled up only for wide-blast-radius work (for plan-time
     panels the triggers and round budget are `review-gate.md`). Keep **at least one non-Opus
     voice** so a systematic Opus blind spot can't survive the panel.
3. **Nominate → adjudicate — never flat-vote.** Every panelist — the depth lens included —
   *nominates* candidate findings; a single **Opus** pass *adjudicates* which are real. Breadth
   lenses exist to widen the net, so they raise candidates that don't hold up; counting those as
   votes turns each one into a repair round.
4. **Dispatch by agent type, so the mix is real.** The type (`sl-depth-reviewer`,
   `sl-panel-reviewer`, `sl-verify-runner`, …) carries both model and effort; `general-purpose`
   inherits the session's. The Agent tool's `model:` param overrides the model only (see "Effort").
5. **Adjudicate inline, on Opus.** By default the deciding pass is the **main thread, inline** — it
   already holds the panel's returns. The main thread runs on the session model (named in its
   system prompt), which is usually Opus but not guaranteed: if it is not Opus, or you cannot tell,
   dispatch **`sl-adjudicator`** (opus/medium) instead. `sl-adjudicator` is only that non-Opus
   fallback. Never let a non-Opus thread be the final arbiter — that is Sonnet ruling on Sonnet's
   nominations. **Effort differs between the two paths.** A dispatched `sl-adjudicator` runs at its
   definition's `medium` — the tier the DriftwisePortal#1994 audit chose for the fallback, because
   it rules by opening each cited anchor, not by deliberating. The inline pass has no agent file of
   its own, so it runs at the effort of whatever skill is active on the thread (`high` inside
   `sl-issue`, `sl-plan`, `sl-ship`, `sl-verify` and `sl-subtask`); this file cannot pin it.
6. **Stop at diminishing returns.** Past ~4–5 reviewers you mostly re-find the same issues. Spend
   the marginal token on another *lens*, a *different model*, or an *actual test/tool run*. (That is
   panel size; how many run *at once* is rule (c) below — a panel bigger than the cap runs in
   batches.)

## Verification panel

`sl-verify` dispatches verifiers under these rules; its escalation trigger list lives in
`sl-verify` ("Model & panel policy") — the one copy, which `sl-ship` step 1 also reads for review effort.

- **Every verifier is an `sl-verify-runner`** (sonnet/medium by definition). Only the **model**
  escalates; effort stays the runner's medium on every dispatch, because the running service —
  not deliberation — decides the verdict.
- **Default:** one fresh `sl-verify-runner` on its definition's defaults.
- **Escalate the model on a trigger.** When the diff hits `sl-verify`'s trigger list, dispatch the
  primary with **`model: opus`** — Opus depth at the runner's medium effort. An unmet requirements
  row is a hard gate, so the requirements-traceability pass runs on `model: opus` too — and since
  the primary runs that pass in the same dispatch, an issue-driven verify dispatches its primary on
  `model: opus` even when no trigger is hit.
- **Second panelist — opt-in.** Add one more `sl-verify-runner` (definition defaults) with a
  *different lens* (edge-cases / error states, vs. the primary's happy path + requirement) **only
  when** the caller passed `--thorough` **or** the change touches one of the trigger list's
  high-stakes surfaces. The size trigger alone raises the model, not the panel. "Multi-file" alone
  does not qualify.
- **Adjudicate** the verdicts per step 5 above — inline when the thread is Opus, else
  `sl-adjudicator`. A single-panelist flag is a *candidate* until adjudicated. An unmet
  requirements row is a FAIL regardless of the panel.

## Writing skills for Opus 5.x and later

Opus 5.x follows an instruction the first time it reads it, and spends effort in proportion to what
it is asked. Four rules follow for every skill and agent in this repo:

- **(a) State each rule once.** A rule lives in one file; every other file points at it. Repeating
  it — or restating it in capitals — does not raise compliance on Opus 5.x; it spends context on
  every run and lets the copies drift apart. This file is that one place for model policy, so no
  skill carries its own model paragraph: a skill names the agent it dispatches in its step text and
  leaves the why to this file.
- **(b) No exhortations to "verify" or to "be thorough".** A sentence urging care changes nothing
  on a model that is already careful, and on a core role it can push the model into re-checking
  what was already decided. What stays is the *structure*: an independent, execution-grounded
  verifier (`sl-verify` and its runner) and a fresh adjudication pass. Those are dispatches, not
  adjectives.
- **(c) Cap subagent spawns explicitly.** Opus 5.x fans out as wide as a task seems to invite, so
  every dispatched worker carries a number, never "as many as needed". The cap lives in
  `agents/sl-core-worker.md` (counting everything a spawned agent spawns in turn); `sl-issues`
  step 4b repeats it in the brief it hands each item. A skill that wants a bigger panel runs it in
  batches — it never drops a panel member, verifier or gate to fit.
- **(d) Pin effort; don't ask for it.** Effort is set in frontmatter (agent or skill), the session
  default, or a Workflow script — never in prose. A sentence asking a dispatched agent to "think
  hard" or "go quickly" is a no-op; see "Effort" below.

## Quick reference

| Role | Model | Effort | Dispatch as |
|------|-------|--------|-------------|
| Plan / architect | **Opus** | **high** | main thread, inline — never a planning agent |
| Author / implement | **Opus** | **high** | main thread; `sl-core-worker` when a skill hands the role to a fresh agent (`sl-issues` items, `sl-issue`'s ship handoff) |
| Adjudicate panel findings | **Opus** | the active skill's (inline); **medium** as `sl-adjudicator` | main thread, inline (the default); `sl-adjudicator` when the session is not Opus |
| Verify (behaviour + requirements) | **Sonnet**, → Opus on `sl-verify`'s triggers and for the requirements pass | **medium** | `sl-verify-runner` |
| Ground the plan in real files | inherit | inherit | inline for ≤2 surfaces; else `Explore`, ≤3 (`sl-plan` / `sl-subtask` step 2) |
| Review panel — depth lens | **Opus** | **high** | `sl-depth-reviewer` |
| Review panel — breadth lenses (×1–2) | **Sonnet** | **medium** | `sl-panel-reviewer` — decorrelation comes from *being a different model*, not from thinking longer |
| Mechanical checks (build/test/lint) | — | — | **inline, main thread** — an exit code has no authoring bias |

## Effort — the second axis, and where it's actually enforced

Model buys *capability per shot*; effort buys *how long the model deliberates before answering*. A
role can want one without the other — verification wants a competent model but little
deliberation (the test run already decided), while adjudication wants both.

**Effort cannot be set on an Agent-tool call.** The Agent tool takes a `model:` param but **no
effort param**, so a skill that merely *writes* "dispatch this at medium effort" changes nothing.
Effort is pinned in exactly four places:

1. **Agent definitions** — `.claude/agents/<name>.md` frontmatter (`effort:` + `model:`). This is
   why the table above names a **dispatch type** rather than a bare model: the agent file is the
   only thing that makes the effort real.
2. **Skill frontmatter** — `effort:` (and `model:`) in a `SKILL.md`. It overrides the session
   default on the thread that invokes the skill; an agent the skill dispatches by type runs at its
   own definition's effort. What the Claude Code docs say about duration (checked 2026-09-24,
   Claude Code 2.1.282, DriftwisePortal#1994 audit):
   - **`model:` lasts for the rest of the turn** (code.claude.com/docs/en/skills: *"The override
     applies for the rest of the current turn and isn't saved to settings."*). So **a skill that a
     core role invokes in-thread must not pin `model:`** — it would leave the rest of that turn,
     authoring and adjudication included, on the pinned tier. That is why `sl-start-env` carries no
     `model:` line.
   - **How long `effort:` lasts is not defined** — the docs don't say whether a skill stops being
     "active" at the end of the Skill call or of the turn. So an in-thread skill that pins a lower
     effort (`sl-start-env`, `low`) may or may not lower the rest of the invoking orchestrator's
     turn.
   - **No doc says whether a subagent that invokes a pinned skill takes that skill's `model:` or
     `effort:`.** The one documented way to confine a skill's model and effort to that skill is
     `context: fork`, which runs it as its own subagent.
3. **The session default** — `effortLevel` in settings, `claude --effort <level>`, or
   `CLAUDE_CODE_EFFORT_LEVEL`. It governs the main thread. **An Opus 5.5 main thread runs at
   `medium`**: the docs' resolution order says *"Opus 5.5 starts at `medium` unless one of the
   sources above sets a level for it, and a top-level `effortLevel` in your user settings file
   doesn't count for Opus 5.5"* (code.claude.com/docs/en/model-config). `~/.claude/settings.json`
   sets a top-level `effortLevel: "high"` and has no `claude-opus-5-5` entry under
   `modelSettings`, so that `high` does not reach an Opus 5.5 session. The core roles get `high`
   from the orchestrators' own `effort: high` frontmatter (`sl-issue`, `sl-plan`, `sl-ship`,
   `sl-verify`, `sl-subtask`) and from `sl-core-worker` when dispatched — not from the session.
   Changing the default is a settings decision (`/effort` saves a `claude-opus-5-5` entry), never
   something a skill does.
4. **Workflow scripts** — `agent(prompt, {effort: 'low'})`.

**The `model:` param still overrides the definition per call.** `subagent_type: sl-verify-runner`
+ `model: opus` gives an Opus verifier at the runner's medium effort — the right shape for a
contract, persistence, or auth change, and the reason the runner can default cheap without losing
the escalation path.

**Scale effort to how much the answer depends on deliberation, not to how much it matters.** A hard
gate matters enormously and still doesn't need high effort if what decides it is a request returning
a 200. Conversely a subtle auth question can matter little in isolation and still need high effort,
because nothing but reasoning will surface it. Ask: *would thinking longer change this answer?* If
it comes from a tool, a test run, or a fixed rubric — it wouldn't.

## Notes

- **Proportionality.** A one-line change doesn't need a panel. Scale to blast radius: trivial →
  a single verifier; contract/persistence/auth → escalate the model and add a second lens.
- **Applies to:** `sl-issue`, `sl-issues`, `sl-ship`, `sl-verify`, `sl-plan`, `sl-subtask` — every
  skill that dispatches subagents or runs an LLM-judgment pass, except the mechanical skills below.
- **Mechanical skills** sit outside this policy, in three groups:
  - **Pinned to `model: sonnet`** in their own frontmatter — `sl-start-embed` (low),
    `sl-create-integration` (medium). Nothing in them takes a judgment a stronger tier would make
    differently, and both are user-invoked only, so the pin cannot reach a core role.
  - **On the invoking thread's model, deliberately** — `sl-start-env` (`effort: low`, no `model:`).
    Core roles invoke it in-thread (e.g. `sl-issue` step 3 boots it before running the AT pack), and
    a `model:` pin would drop everything after it in the turn onto Sonnet (see "Effort", item 2). If
    a skill a core role invokes in-thread ever needs a cheaper tier, run it as a dispatched agent or
    with `context: fork`.
  - **Left on the session model, deliberately** — `sl-deploy` (`effort: medium`). Just as
    mechanical, but it ships production, and the saving on a handful of short runs doesn't justify a
    cheaper tier misreading a deploy gate. Its gates are scripts, so thinking longer would not
    change a pass or a refusal.
- **The five agent definitions this policy depends on** live in `.claude/agents/`:
  `sl-verify-runner` (sonnet/medium), `sl-panel-reviewer` (sonnet/medium), `sl-adjudicator`
  (opus/medium), `sl-depth-reviewer` (opus/high), `sl-core-worker` (opus/high). Changing a role's
  effort means editing that file — editing this doc alone does nothing.
