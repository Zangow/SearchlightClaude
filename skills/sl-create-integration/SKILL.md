---
name: sl-create-integration
description: Author a best-first-attempt Searchlight integration config for ANY third-party platform's API — investigate its docs, classify ingestion mode and auth, map every category onto the 6 standard schemas (with transforms + config-driven hydration), self-test through the admin mapping-preview / dry-run endpoints, verify the draft with a fresh subagent, and SAVE it as a draft (never publish) with a handoff report for human review. Use when asked to "create/onboard/set up an integration", "build a config for <platform>", or "map <platform>'s API onto the standard schemas".
---

# sl-create-integration

> **This skill is a thin local alias.** Its authoritative instructions are the committed
> product deliverable (issue #21) and are **not** duplicated here, so the two never drift.

**Do this now:** read the canonical skill file and follow it EXACTLY, top to bottom:

```
/Users/danieljohnston/git/Searchlight/IntegrationService/skills/create-integration/SKILL.md
```

Everything below that file's frontmatter is your operating instructions. All of its
relative paths resolve against **its own** directory
(`.../IntegrationService/skills/create-integration/`), so read its `reference/*` before
mapping (never guess field names), and use its `scripts/` (`sl-admin.sh`, `check-config.sh`)
and `examples/` from there — not from this alias directory.

Honor its guardrails without exception: **never publish** (drafts only — publishing is a
human step in the admin UI), **never persist credentials**, read-only capped probing, and
never hand off a draft with known-failing checks. The admin API env it expects
(`ADMIN_BASE_URL` / `ADMIN_API_KEY`, defaulting to `http://localhost:8080` / `local-admin-key`)
needs the local stack up first — `/sl-start-env backend`.
