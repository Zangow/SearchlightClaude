#!/usr/bin/env bash
#
# sl-worktree.sh — git-worktree isolation for issue-driven Searchlight work.
#
# WHY: the Searchlight repo(s) live at $SL_BASE_PATH/<Repo>, and every sl-*
# skill resolves repos as "$SL_BASE_PATH/<Repo>". So to make a whole skill run
# (sl-verify, sl-ship, …) operate on an *isolated* checkout, we don't patch
# every skill — we build a "shadow base" directory that holds a git worktree of
# each repo, then the caller repoints SL_BASE_PATH at it for that session.
# Everything downstream then transparently uses the worktrees.
#
# This gives PARALLEL AUTHORING: two Claude sessions on two issues edit/commit/
# push fully isolated source trees. If verification ever needs a shared
# singleton resource (bound ports, a shared dev DB), serialize through the
# env-claim mutex below; until then it goes unused.
#
# Worktrees live at:  <real-base>/.sl-worktrees/<name>/<Repo>
# where <real-base> = "${SL_REAL_BASE:-$SL_BASE_PATH}" so it resolves correctly
# both before repointing (SL_BASE_PATH is the real base) and after (the session
# has SL_REAL_BASE=real base, SL_BASE_PATH=the worktree root).
#
# Usage:
#   sl-worktree.sh create <name> <branch> [<Repo>...]   # prints the worktree ROOT
#                                                        # <Repo> defaults to IntegrationService
#   sl-worktree.sh root   <name>                         # prints the worktree ROOT
#   sl-worktree.sh list                                  # list worktree names
#   sl-worktree.sh remove <name> [--force]              # remove all worktrees for <name>
#   sl-worktree.sh env-claim [--wait]                    # mark current SL_BASE_PATH as env owner
#   sl-worktree.sh env-owner                             # print current env-owner root ("" if none)
#   sl-worktree.sh env-release [--force]                 # clear the env-owner marker
#
# Typical wiring inside sl-issue's default worktree mode (skipped with --skip-worktree):
#   ROOT=$(sl-worktree.sh create issue-12-foo feat/issue-12-foo)
#   export SL_REAL_BASE="$SL_BASE_PATH"        # remember the true base
#   export SL_BASE_PATH="$ROOT"                # every later skill now uses the worktree
#   # …author / sl-ship / sl-verify…
#   sl-worktree.sh remove issue-12-foo         # after the PR is up
#
# NEVER persist the repointed SL_BASE_PATH to a shell profile — it's session-only.
set -euo pipefail

BASE="${SL_REAL_BASE:-${SL_BASE_PATH:-/Users/danieljohnston/git/Searchlight}}"
WT_DIR="$BASE/.sl-worktrees"
LOCK_DIR="$WT_DIR/.env-lock"        # atomic mutex (mkdir) — only one checkout holds the env
OWNER_FILE="$LOCK_DIR/owner"
DEFAULT_REPO="IntegrationService"

cmd="${1:?usage: create|root|list|remove|env-claim|env-owner|env-release}"
shift || true

case "$cmd" in
  create)
    name="${1:?worktree name required}"; branch="${2:?branch required}"; shift 2
    [ "$#" -ge 1 ] || set -- "$DEFAULT_REPO"
    root="$WT_DIR/$name"
    mkdir -p "$root"
    for repo in "$@"; do
      src="$BASE/$repo"
      dest="$root/$repo"
      [ -d "$src/.git" ] || [ -f "$src/.git" ] || { echo "not a git repo: $src" >&2; exit 1; }
      if [ -e "$dest" ]; then
        echo "reuse: $dest already exists" >&2
        continue
      fi
      git -C "$src" fetch origin main --quiet
      # Branch off the freshly-fetched main. Reuse the branch if it already exists
      # (e.g. a re-run after the branch was pushed), else create it.
      if git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$src" worktree add --quiet "$dest" "$branch"
      else
        git -C "$src" worktree add --quiet "$dest" -b "$branch" origin/main
      fi
      # Publish immediately so interrupted work has a remote home.
      git -C "$dest" push -u origin "$branch" --quiet 2>/dev/null || true
      echo "worktree: $repo -> $dest (branch $branch)" >&2
    done
    echo "$root"          # stdout = the ROOT the caller exports as SL_BASE_PATH
    ;;

  root)
    name="${1:?worktree name required}"
    echo "$WT_DIR/$name"
    ;;

  list)
    [ -d "$WT_DIR" ] || exit 0
    find "$WT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.env-lock' -exec basename {} \; | sort
    ;;

  remove)
    name="${1:?worktree name required}"; shift || true
    force=""
    [ "${1:-}" = "--force" ] && force="--force"
    root="$WT_DIR/$name"
    [ -d "$root" ] || { echo "no such worktree: $root" >&2; exit 0; }
    # Remove each repo's worktree via its source repo so git's metadata is
    # cleaned. A failed removal doesn't abort the loop — keep going so the
    # other repos still get cleaned, and report all the stuck ones at the end.
    stuck=""
    for dest in "$root"/*; do
      [ -d "$dest" ] || continue
      repo="$(basename "$dest")"
      src="$BASE/$repo"
      if [ -d "$src" ]; then
        git -C "$src" worktree remove ${force:+--force} "$dest" 2>/dev/null \
          || stuck="$stuck $dest"
      fi
    done
    rmdir "$root" 2>/dev/null || true
    # Release the env mutex if this worktree was holding it — even on partial
    # failure, since the checkout is unusable either way.
    if [ -f "$OWNER_FILE" ] && [ "$(cut -f1 "$OWNER_FILE")" = "$root" ]; then
      rm -rf "$LOCK_DIR"
    fi
    if [ -n "$stuck" ]; then
      echo "could not remove:$stuck (uncommitted changes? re-run with --force)" >&2
      exit 1
    fi
    echo "removed: $root" >&2
    ;;

  env-claim)
    # Acquire the singleton-env mutex for the current checkout. The lock is an
    # atomic `mkdir` so two sessions racing can't both win. Re-claiming a lock
    # you already hold is a no-op success (idempotent across boots in a session).
    #   env-claim          -> claim, or exit 2 (printing the owner) if held by another
    #   env-claim --wait   -> block, polling until the env frees, then claim
    #                         (bounded: gives up with exit 3 after 30 minutes)
    # NOTE: no PID-liveness reclaim on purpose — every harness Bash call is a
    # new process, so the claiming PID is always dead; PID-based reclaim would
    # destroy the mutex. Reclaim only on the two provably-stale cases below.
    mkdir -p "$WT_DIR"
    me="${SL_BASE_PATH:?SL_BASE_PATH must be set}"
    wait="no"; [ "${1:-}" = "--wait" ] && wait="yes"
    start="$(date +%s)"
    while true; do
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$me" "$(hostname)" "$(date +%s)" > "$OWNER_FILE"
        echo "$me"; exit 0
      fi
      cur="$(cut -f1 "$OWNER_FILE" 2>/dev/null || true)"
      if [ "$cur" = "$me" ]; then echo "$me"; exit 0; fi   # already mine
      now="$(date +%s)"
      if [ -z "$cur" ]; then
        # Lock dir exists but the owner file is missing/empty — a session
        # crashed between mkdir and writing the owner. Give the normal
        # sub-second mkdir→write window ~15s of grace, then reclaim.
        lock_mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo "$now")"
        if [ $((now - lock_mtime)) -gt 15 ]; then
          echo "reclaiming orphaned env lock (no owner recorded)" >&2
          rm -rf "$LOCK_DIR"; continue
        fi
      elif [ ! -e "$cur" ]; then
        # Owner checkout no longer exists on disk (worktree removed without
        # env-release) — the lock can never be released by its owner; reclaim.
        echo "reclaiming env lock from removed checkout: $cur" >&2
        rm -rf "$LOCK_DIR"; continue
      fi
      if [ "$wait" = "yes" ]; then
        elapsed=$((now - start))
        if [ "$elapsed" -ge 1800 ]; then
          echo "env still held by $cur after 30m — inspect with 'sl-worktree.sh env-owner'; clear a crashed session's lock with 'sl-worktree.sh env-release --force'" >&2
          exit 3
        fi
        echo "waiting for env (owner: $cur, ${elapsed}s)" >&2
        sleep 5; continue
      fi
      echo "ENV BUSY: owned by ${cur:-<unknown>}" >&2
      echo "${cur:-}"; exit 2
    done
    ;;

  env-owner)
    [ -f "$OWNER_FILE" ] && cut -f1 "$OWNER_FILE" || true
    ;;

  env-release)
    # Release the mutex. Refuse to release another checkout's lock unless --force
    # (use --force to clear a stale lock left by a crashed session).
    cur="$(cut -f1 "$OWNER_FILE" 2>/dev/null || true)"
    me="${SL_BASE_PATH:-}"
    if [ -n "$cur" ] && [ "$cur" != "$me" ] && [ "${1:-}" != "--force" ]; then
      echo "env held by $cur (not you) — pass --force to clear a stale lock" >&2
      exit 1
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    ;;

  *)
    echo "unknown command: $cmd" >&2
    exit 1
    ;;
esac
