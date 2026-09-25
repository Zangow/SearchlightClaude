#!/usr/bin/env bash
#
# gradle-busy.sh — is somebody else's Gradle build already running over this checkout?
#
# WHY: two Gradle runs over one IntegrationService tree fake a failure — ~60 classes of "Could not
# write XML test results" plus unrelated PartnerS3IngestionE2EIT failures — that reads like a
# regression. Run this before `./gradlew check`/`test` and wait or report; never kill a build you
# cannot prove you started. See _shared/waiting.md rule D and _shared/testing-policy.md §3.
#
# Usage: gradle-busy.sh <repo-dir> [--wait SECONDS]      SECONDS: 1..540
#   exit 0  clear (or became clear within --wait)
#   exit 4  busy — prints "PID ETIME COMMAND" for each build found
#   exit 2  usage error / not a directory
#
# A build counts when its root and <repo-dir> overlap (equal, or one inside the other, on path
# boundaries — /x/Repo does not overlap /x/Repo2). Matched:
#   - a wrapper client (`./gradlew …`), by the path of the gradle-wrapper.jar it runs
#     (<root>/gradle/wrapper/gradle-wrapper.jar), else by its cwd
#   - a test worker ("Gradle Test Executor"), by its cwd — the project it is testing
# Excluded: anything running bootRun — the warm service sl-start-env keeps up on purpose — and the
# Gradle daemon itself, which is shared across checkouts and idles between builds.
# Paths are compared in physical (pwd -P) form, so a symlinked ancestor cannot hide a build.
#
# Test hooks (used by test-gradle-busy.sh): GRADLE_BUSY_PS_CMD replaces `ps -Ao pid=,etime=,command=`,
# GRADLE_BUSY_LSOF_CMD replaces `lsof -a -d cwd -Fn -p` (the PID is appended), GRADLE_BUSY_POLL_SECS
# replaces the 10 s --wait poll interval.
set -uo pipefail

usage() { echo "usage: gradle-busy.sh <repo-dir> [--wait SECONDS(1..540)]" >&2; exit 2; }

[ $# -ge 1 ] || usage
DIR_ARG="$1"; shift
WAIT=0
if [ $# -gt 0 ]; then
  [ "$1" = "--wait" ] && [ $# -eq 2 ] || usage
  case "$2" in ''|*[!0-9]*) usage ;; esac
  WAIT=$((10#$2))
  [ "$WAIT" -ge 1 ] && [ "$WAIT" -le 540 ] || usage
fi
[ -d "$DIR_ARG" ] || { echo "gradle-busy: not a directory: $DIR_ARG" >&2; exit 2; }
TARGET="$(cd "$DIR_ARG" && pwd -P)"

PS_CMD="${GRADLE_BUSY_PS_CMD:-ps -Ao pid=,etime=,command=}"
LSOF_CMD="${GRADLE_BUSY_LSOF_CMD:-lsof -a -d cwd -Fn -p}"
POLL="${GRADLE_BUSY_POLL_SECS:-10}"

physical() {  # resolved when it exists, else as given
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" && pwd -P); else printf '%s\n' "${p%/}"; fi
}

overlaps() {  # $1 $2 — equal, or one is inside the other on a path boundary
  [ -n "$1" ] || return 1
  [ "$1" = "$2" ] && return 0
  case "$1/" in "$2"/*) return 0 ;; esac
  case "$2/" in "$1"/*) return 0 ;; esac
  return 1
}

cwd_of() {  # $1 pid → physical cwd, or nothing
  local n
  set -f
  # shellcheck disable=SC2086  # LSOF_CMD is a command line on purpose
  n="$($LSOF_CMD "$1" 2>/dev/null | sed -n 's/^n//p' | head -1)"
  set +f
  [ -n "$n" ] && physical "$n"
}

wrapper_root() {  # $1 command → <root> from ".../<root>/gradle/wrapper/gradle-wrapper.jar"
  local tok
  set -f
  for tok in $1; do
    case "$tok" in
      */gradle/wrapper/gradle-wrapper.jar) set +f; printf '%s\n' "${tok%/gradle/wrapper/gradle-wrapper.jar}"; return 0 ;;
    esac
  done
  set +f
  return 1
}

scan() {  # prints busy lines; returns 0 if any
  local found=1 pid etime cmd root table
  set -f
  # shellcheck disable=SC2086
  table="$($PS_CMD 2>/dev/null)"
  set +f
  while read -r pid etime cmd; do
    [ -n "${pid:-}" ] || continue
    case "$pid" in *[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    case "$cmd" in *bootRun*|*GradleDaemon*) continue ;; esac
    root=""
    case "$cmd" in
      *gradle-wrapper.jar*|*GradleWrapperMain*)
        if root="$(wrapper_root "$cmd")"; then root="$(physical "$root")"; else root="$(cwd_of "$pid")"; fi ;;
      *"Gradle Test Executor"*)
        root="$(cwd_of "$pid")" ;;
      *) continue ;;
    esac
    if overlaps "$root" "$TARGET"; then
      printf '%s %s %.200s\n' "$pid" "$etime" "$cmd"
      found=0
    fi
  done <<EOF
$table
EOF
  return $found
}

start=$SECONDS
while :; do
  if ! busy="$(scan)"; then exit 0; fi
  if [ $((SECONDS - start)) -ge "$WAIT" ]; then
    echo "gradle-busy: Gradle build(s) running over $TARGET:" >&2
    printf '%s\n' "$busy"
    exit 4
  fi
  sleep "$POLL"
done
