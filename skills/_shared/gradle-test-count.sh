#!/usr/bin/env bash
#
# gradle-test-count.sh — how many tests did the last Gradle run of each suite actually execute?
#
# WHY: IntegrationService's build has no `testLogging`, so Gradle's console never prints a test
# count and `BUILD SUCCESSFUL` is all a run shows — including a run that executed zero tests of the
# kind being claimed (a skipped task, an `assumeTrue` skip, a filter). The count lives in the JUnit
# XML each Test task writes; this prints it. See _shared/testing-policy.md §3.
#
# Usage: gradle-test-count.sh <IntegrationService-dir> [suite ...]
#   suite: a results directory name — `test`, `integrationTest`, `boundedHeapTest`, or a
#          subproject's as `<subproject>:<suite>`, e.g. `acceptance-tests:test`,
#          `acceptance-tests:acceptanceTest`.
#   No suites named → every suite found except `acceptance-tests:acceptanceTest` (the live pack,
#   which sits outside `./gradlew check`).
#
# Prints one line per suite, then a TOTAL line:
#   <suite> files=N tests=T skipped=S failures=F errors=E executed=T-S newest=<suite timestamp, UTC>
#   exit 0  every listed suite executed >= 1 and failures+errors == 0
#   exit 1  some suite has failures or errors
#   exit 3  a named suite has no reports, or some suite executed 0 tests
#   exit 2  usage error / not a directory
#
# `newest` is the latest <testsuite timestamp=…> in that suite. A suite whose Gradle task did not
# run (or report UP-TO-DATE) in the run you are evidencing still has older reports on disk — compare
# `newest` with the run's start before quoting it.
set -uo pipefail

usage() { echo "usage: gradle-test-count.sh <IntegrationService-dir> [suite ...]" >&2; exit 2; }

[ $# -ge 1 ] || usage
ROOT="$1"; shift
[ -d "$ROOT" ] || { echo "gradle-test-count: not a directory: $ROOT" >&2; exit 2; }

results_dir() {  # suite name → its results directory
  case "$1" in
    *:*) printf '%s/%s/build/test-results/%s\n' "$ROOT" "${1%%:*}" "${1#*:}" ;;
    *)   printf '%s/build/test-results/%s\n' "$ROOT" "$1" ;;
  esac
}

SUITES=()
if [ $# -gt 0 ]; then
  SUITES=("$@")
else
  for d in "$ROOT"/build/test-results/*/ "$ROOT"/*/build/test-results/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; name="${d##*/}"
    [ "$name" = binary ] && continue
    case "$d" in
      "$ROOT"/build/test-results/*) s="$name" ;;
      *) sub="${d#"$ROOT"/}"; s="${sub%%/*}:$name" ;;
    esac
    [ "$s" = "acceptance-tests:acceptanceTest" ] && continue
    SUITES+=("$s")
  done
fi
[ ${#SUITES[@]} -gt 0 ] || { echo "gradle-test-count: no test reports under $ROOT — has a test task run?" >&2; exit 3; }

rc=0
tt=0 ts=0 tf=0 te=0
for s in "${SUITES[@]}"; do
  dir="$(results_dir "$s")"
  shopt -s nullglob
  files=("$dir"/TEST-*.xml)
  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    echo "$s files=0 (no reports at $dir)"
    [ "$rc" -eq 0 ] && rc=3; continue
  fi
  # The first <testsuite …> element of each file carries the per-class totals.
  read -r n t sk f e newest < <(awk '
    FNR == 1 { seen = 0 }
    !seen && /<testsuite[ >]/ {
      seen = 1; n++
      t  += attr($0, "tests");    sk += attr($0, "skipped")
      f  += attr($0, "failures"); e  += attr($0, "errors")
      if (match($0, /timestamp="[^"]*"/)) {
        ts = substr($0, RSTART + 11, RLENGTH - 12); if (ts > newest) newest = ts
      }
    }
    function attr(line, name,   re) {
      re = " " name "=\"[0-9]+\""
      if (!match(line, re)) return 0
      return substr(line, RSTART + length(name) + 3, RLENGTH - length(name) - 4) + 0
    }
    END { printf "%d %d %d %d %d %s\n", n, t, sk, f, e, (newest == "" ? "-" : newest) }
  ' "${files[@]}")
  x=$((t - sk))
  echo "$s files=$n tests=$t skipped=$sk failures=$f errors=$e executed=$x newest=$newest"
  tt=$((tt + t)); ts=$((ts + sk)); tf=$((tf + f)); te=$((te + e))
  if [ $((f + e)) -gt 0 ]; then rc=1
  elif [ "$x" -lt 1 ] && [ "$rc" -eq 0 ]; then rc=3
  fi
done
echo "TOTAL tests=$tt skipped=$ts failures=$tf errors=$te executed=$((tt - ts))"
exit "$rc"
