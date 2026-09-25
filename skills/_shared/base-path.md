# `$SL_BASE_PATH` — where the Searchlight checkouts live

**Base path is `$SL_BASE_PATH`**, defaulting to `/Users/danieljohnston/git/Searchlight` — the
workspace container that holds the two repos (see `~/git/Searchlight/CLAUDE.md`). It is **not** a
git repo itself. Every sl-* skill resolves the product repo as **`$SL_BASE_PATH/IntegrationService`**.

Skills point here with one line instead of restating it:

```
> **Repo paths use `$SL_BASE_PATH`** — resolve it per `_shared/base-path.md`.
```

## Resolve it first

1. **Already set? Use it as-is.** Never re-derive a value that is already set — in worktree mode it
   deliberately points somewhere else (below). **Exception — `sl-deploy`:** deploys never run from a
   worktree, so it resolves the real base: `export SL_BASE_PATH="${SL_REAL_BASE:-$SL_BASE_PATH}"`.
2. **Unset → the default:** `export SL_BASE_PATH="${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}"`.
3. **Verify:** `test -d "$SL_BASE_PATH/IntegrationService"`. A miss means the value is wrong — stop
   and say so (a subagent returns it to its caller); don't guess another path.

## Worktree mode (`sl-issue`'s default)

`sl-worktree.sh create` builds a shadow base at `$SL_REAL_BASE/.sl-worktrees/<name>/` holding a
worktree of IntegrationService, and the session repoints:

- **`SL_BASE_PATH`** → that worktree root, so `$SL_BASE_PATH/IntegrationService` is the worktree.
  Skills that only build, test, verify or ship work unchanged.
- **`SL_REAL_BASE`** → the true base. Anything that is **not** in the IntegrationService repo
  resolves through **`${SL_REAL_BASE:-$SL_BASE_PATH}`**: requirements checklists
  (`.sl-issue/`, `.sl-plan/`, `.sl-subtask/`), and this repo's helpers
  (`${SL_REAL_BASE:-$SL_BASE_PATH}/.claude/skills/_shared/*.sh`) — the worktree root has no `.claude/`.

**Never persist the repointed `SL_BASE_PATH`** to a shell profile — it is session-only.

## Every Bash call is a fresh shell

An `export` from an earlier Bash call is gone in the next one. Start any call that needs the
values with them — in worktree mode, both:
`export SL_REAL_BASE="<true base>" SL_BASE_PATH="<worktree root>";` — or use absolute paths.
Env vars do **not** cross an agent boundary either: a brief handed to a subagent spells both
exports out verbatim, or a worktree run silently operates on the main checkout.
