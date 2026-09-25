# `testing-policy.md` — which level of test a change ships with, and what may back a green claim (HARD RULE)

The standing test policy for every IntegrationService change, stated once. `sl-issue` (step 3),
`sl-plan` (the `### Tests` template), `sl-subtask` (tests ship with their card), `sl-verify`
(steps 2a and 2b), `sl-ship` (steps 1 and 2) and `agents/sl-verify-runner.md` point here instead of
restating it. Each of them keeps only what is specific to its own step: when to apply the policy,
and what to do when a row falls short.

## 1. Which level: acceptance test by default, and the unit/integration layer always

1. **Every new feature and every bug fix lands acceptance-test coverage** of its externally
   observable outcome. This is the default. A change that ships without an AT carries a decision
   someone has to justify (rule 3); it is never a silent omission. The reason is deployment: the AT
   pack is what `sl-deploy` runs against QA, and on a QA→PROD run it is what gates PROD. A behaviour
   with no AT is a behaviour nobody checks after a deploy.
2. **Extend an existing spec before writing a new one.** Find the test that already exercises that
   endpoint or flow and add the case or assertion there. A new spec is warranted only when nothing
   covers the flow, or when folding it in would make one test cover two unrelated things. Search
   first (`rg -l "<endpoint|flow|slug>" acceptance-tests/src e2e/specs src/integrationTest`), then
   say which you did and which spec.
   - **`acceptance-tests/`** (`AcceptanceTestBase` subclasses): black-box HTTP + S3 against a
     *running* target. Admin API, catalog/authZ, registration → poll/push → delivery,
     idempotency/residue.
   - **`e2e/specs/*.spec.ts`** (Playwright): real-browser flows through the admin UI and the
     customer embed card. This is the AT layer for `ui/` and `ui-embed/` work.
   - **`src/integrationTest/`** (Testcontainers: Postgres + LocalStack, needs Docker): anything
     crossing persistence/S3/Secrets that isn't observable from outside.
3. **When an AT genuinely doesn't fit, use unit/integration instead, and record why.** Legitimate
   cases: a pure helper or formatter, an internal branch no API or UI surface can reach, a condition
   the pack can't provoke without absurd fixture gymnastics, or a signal that isn't observable in a
   deployed env at all. **Micrometer counters are the standing example**: there is no exporter, so
   plan a log line or an API-observable signal instead. Put the reason in the plan or checklist and
   in the PR body, so a reviewer sees it was a call and not an oversight.
4. **Unit/integration tests are required even when an AT is added.** They are not alternatives. The
   AT proves the outcome end-to-end; the unit/integration layer pins the logic, edge cases and
   error paths at the level where a failure tells you what broke.

**Derive the tests from the requirements, not the code:** one named test per testable checklist row
(`R3 → test('biz-reply events are filtered before delivery')`). Post-hoc tests encode what the code
*does*, not what the issue *required*.

**Record the level per row** in the requirements checklist's Evidence column, e.g.
`AT: RegistrationPollDeliveryAcceptanceTest (extended, run vs local)` + `unit: RecordFilterTest`, so
`sl-verify`'s requirements pass can check both layers.

## 2. Removing a test is a FAIL unless a checklist row licenses it

A diff that deletes a test, adds `@Disabled` / `test.skip`, or weakens an assertion to go green is a
verification **FAIL**, for the author and for every verifier after it, unless the checklist names
the row that removes *that behaviour*. Fix the fixture or the code, never the test.

## 3. What may back a green claim

`IntegrationService/CLAUDE.md` ("Build / test / run") is the source of truth for the Gradle tasks.
If this section and that one ever disagree, `CLAUDE.md` wins and this file is the one to fix.

- **Only a full `./gradlew check` backs "green".** "The suite is green", a ✅ row, "PR-ready" and a
  deploy all need `check`, which runs `test`, `integrationTest`, `boundedHeapTest`, `scriptTests`,
  `skillScriptTests` and `:acceptance-tests:test`. A `--tests` filter, `./gradlew test` alone, or
  `-x <task>` is an inner-loop run. It backs a claim about exactly what it ran, and it is reported
  that way, never as the suite.
- **Docker first.** `integrationTest`, and therefore `check`, needs a running Docker daemon for
  Testcontainers. Run `docker info >/dev/null 2>&1` before either. **Docker down → the tier is
  `BLOCKED`, not `FAIL`**: it is an environment fault, fixed by starting Docker and re-running. It
  never costs a repair round, and it is never green. Do not drop to `./gradlew test` and call that
  the suite.
- **Never `-q`.** Quiet mode hides the task list, so you can't see a test task that was `SKIPPED`,
  `NO-SOURCE` or excluded. It also hides the failure detail you would need to tell an environment
  trap from a regression. Run at the default log level (`--console=plain` for a readable log).
- **A count, not `BUILD SUCCESSFUL`.** This build has no `testLogging`, so Gradle's console never
  prints a test count, and a green build can have executed zero tests of the kind you care about.
  Read the JUnit XML with `_shared/gradle-test-count.sh <IntegrationService-dir>` and quote its
  per-suite lines. The evidence is `executed` (tests − skipped) ≥ 1 per suite you claim, with
  `failures=0 errors=0`. A test you added or changed must appear executed, not skipped: the
  acceptance pack skips on `assumeTrue` when its target lacks a bucket.
- **Read the task list too.** The XML of a task that didn't run this time survives from an earlier
  run. A suite whose Gradle task this run reported neither executed nor `UP-TO-DATE` is not
  evidenced by its old reports.
- **One Gradle run per checkout.** Run `_shared/gradle-busy.sh <IntegrationService-dir>` first. A
  concurrent run over the same tree fakes a ~60-class "Could not write XML test results" failure
  (`_shared/waiting.md` rule D).
- **A known environment trap is re-run before it's called a regression.** Examples: that
  concurrent-Gradle signature; an exported `AWS_ENDPOINT_URL` (two script tests fail); an exported
  `ADMIN_API_KEY` (integration tests 401). Unset or quiesce, re-run, then judge.

**An AT nobody has run is not coverage.** `:acceptance-tests:acceptanceTest` is deliberately outside
`check`, because it needs a running target. So a green `check` says nothing about whether a new AT
passes, or even reaches a live endpoint. Run it (`scripts/run-acceptance.sh local` after
`sl-start-env`; `scripts/run-e2e.sh local|qa` for Playwright), then read its count:
`gradle-test-count.sh <dir> acceptance-tests:acceptanceTest`, or Playwright's `N passed` line. An AT
that has not executed is **`BLOCKED`**, never PASS.

## Reference it from a skill like

```
> **Testing policy:** AT by default, unit/integration always, and only a full `./gradlew check` with a quoted test count backs green — per `_shared/testing-policy.md`.
```
