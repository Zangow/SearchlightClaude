#!/usr/bin/env bash
#
# test-gradle-scripts.sh — hermetic tests for gradle-busy.sh and gradle-test-count.sh (#556).
#
# gradle-busy's process table and lsof are stubbed through its test hooks, so no case depends on
# what else is running on the machine. gradle-test-count reads fixture JUnit XML written here.
#
# Run: bash skills/_shared/test-gradle-scripts.sh      (exit 0 = all passed)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"                       # under /var → /private/var on macOS: a symlinked ancestor
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() {  # name expected-exit expected-stdout-substring(or "") -- cmd args...
  local name="$1" want="$2" grepfor="$3"; shift 3
  local out rc
  out="$("$@" 2>/dev/null)"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$grepfor" ] || printf '%s' "$out" | grep -q -- "$grepfor"; }; then
    PASS=$((PASS+1)); echo "ok   $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL $name — exit $rc (want $want); out: $out"
  fi
}

# ---------------------------------------------------------------- gradle-busy.sh
BUSY="$HERE/gradle-busy.sh"
mkdir -p "$T/real/IS/acceptance-tests" "$T/real/IS2" "$T/real/wt/IS"
ln -s "$T/real" "$T/link"
PS="$T/ps.txt"; CWDS="$T/cwds.txt"
cat >"$T/ps.sh" <<EOF
#!/usr/bin/env bash
if [ -f "$T/ps.after" ]; then   # a table that changes after N reads models a build finishing mid --wait
  n=\$(cat "$T/ps.count" 2>/dev/null || echo 0); echo \$((n+1)) >"$T/ps.count"
  [ "\$n" -ge "\$(cat "$T/ps.after")" ] && { cat "$T/ps.later"; exit 0; }
fi
cat "$PS"
EOF
cat >"$T/lsof.sh" <<EOF
#!/usr/bin/env bash
d=\$(awk -v p="\$1" '\$1==p {print \$2}' "$CWDS"); [ -n "\$d" ] && printf 'p%s\nfcwd\nn%s\n' "\$1" "\$d"
EOF
chmod +x "$T/ps.sh" "$T/lsof.sh"
export GRADLE_BUSY_PS_CMD="$T/ps.sh" GRADLE_BUSY_LSOF_CMD="$T/lsof.sh" GRADLE_BUSY_POLL_SECS=1

wrapper() { echo "$1 1:02 /usr/bin/java -Xmx64m -Dorg.gradle.appname=gradlew -classpath \"\" -jar $2/gradle/wrapper/gradle-wrapper.jar ${3:-check}"; }
worker()  { echo "$1 0:40 /usr/bin/java -Xmx512m -cp /h/.gradle/caches/gradle-worker.jar worker.org.gradle.process.internal.worker.GradleWorkerMain 'Gradle Test Executor 7'"; }
daemon()  { echo "$1 9:12:01 /usr/bin/java -Xmx2g -cp /h/.gradle/wrapper/dists/gradle-8.14.3/lib/gradle-daemon-main-8.14.3.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14.3"; }
reset() { rm -f "$T/ps.after" "$T/ps.count" "$T/ps.later"; : >"$CWDS"; : >"$PS"; }

reset
check "empty process table → clear"                    0 ""        "$BUSY" "$T/real/IS"
reset; wrapper 101 "$T/real/IS" >"$PS"
check "wrapper over the same checkout → busy"          4 "^101 "   "$BUSY" "$T/real/IS"
check "same, target named through a symlink → busy"    4 "^101 "   "$BUSY" "$T/link/IS"
check "wrapper root contains the target → busy"        4 "^101 "   "$BUSY" "$T/real/IS/acceptance-tests"
check "sibling with a shared prefix → clear"           0 ""        "$BUSY" "$T/real/IS2"
check "a worktree of the same repo → clear"            0 ""        "$BUSY" "$T/real/wt/IS"
reset; wrapper 102 "$T/real/IS" bootRun >"$PS"
check "bootRun (the warm service) → clear"             0 ""        "$BUSY" "$T/real/IS"
reset; daemon 103 >"$PS"; echo "103 $T/real/IS" >"$CWDS"
check "an idle daemon → clear"                         0 ""        "$BUSY" "$T/real/IS"
reset; worker 104 >"$PS"; echo "104 $T/real/IS/acceptance-tests" >"$CWDS"
check "test worker inside the checkout → busy"         4 "^104 "   "$BUSY" "$T/real/IS"
reset; worker 105 >"$PS"; echo "105 $T/real/wt/IS" >"$CWDS"
check "test worker in another checkout → clear"        0 ""        "$BUSY" "$T/real/IS"
reset; echo "106 0:05 /usr/bin/java -cp x org.gradle.wrapper.GradleWrapperMain test" >"$PS"; echo "106 $T/real/IS" >"$CWDS"
check "old-style GradleWrapperMain, by cwd → busy"     4 "^106 "   "$BUSY" "$T/real/IS"
reset; wrapper 107 "$T/real/IS" >"$PS"; : >"$T/ps.later"; echo 2 >"$T/ps.after"
check "build finishes within --wait → clear"           0 ""        "$BUSY" "$T/real/IS" --wait 10
reset; wrapper 108 "$T/real/IS" >"$PS"
check "still running at the --wait bound → busy"       4 "^108 "   "$BUSY" "$T/real/IS" --wait 1
check "no args → usage"                                2 ""        "$BUSY"
check "--wait 0 → usage"                               2 ""        "$BUSY" "$T/real/IS" --wait 0
check "--wait 541 → usage"                             2 ""        "$BUSY" "$T/real/IS" --wait 541
check "missing directory → usage"                      2 ""        "$BUSY" "$T/real/nope"

# ---------------------------------------------------------------- gradle-test-count.sh
COUNT="$HERE/gradle-test-count.sh"
R="$T/repo"
suite() {  # dir file tests skipped failures errors timestamp
  mkdir -p "$1"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="%s" tests="%s" skipped="%s" failures="%s" errors="%s" timestamp="%s" hostname="h" time="0.1">\n  <properties/>\n  <testcase name="x"/>\n</testsuite>\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" >"$1/TEST-$2.xml"
}
suite "$R/build/test-results/test"            A 3 0 0 0 2026-09-24T17:00:00.000Z
suite "$R/build/test-results/test"            B 2 1 0 0 2026-09-24T17:05:00.000Z
suite "$R/build/test-results/integrationTest" C 4 0 0 0 2026-09-24T17:06:00.000Z
mkdir -p "$R/build/test-results/test/binary"
suite "$R/acceptance-tests/build/test-results/test"           D 1 0 0 0 2026-09-24T17:01:00.000Z
suite "$R/acceptance-tests/build/test-results/acceptanceTest" E 5 5 0 0 2026-09-24T17:02:00.000Z

check "default set: sums per suite"                     0 "^test files=2 tests=5 skipped=1 failures=0 errors=0 executed=4 newest=2026-09-24T17:05:00.000Z" "$COUNT" "$R"
check "default set: subproject suite is named"          0 "^acceptance-tests:test files=1 tests=1" "$COUNT" "$R"
check "default set: TOTAL excludes the live AT pack"    0 "^TOTAL tests=10 skipped=1 failures=0 errors=0 executed=9" "$COUNT" "$R"
check "all-skipped suite → exit 3"                      3 "executed=0"   "$COUNT" "$R" acceptance-tests:acceptanceTest
check "named suite with no reports → exit 3"            3 "files=0"      "$COUNT" "$R" boundedHeapTest
suite "$R/build/test-results/integrationTest" F 2 0 1 0 2026-09-24T17:07:00.000Z
check "a failure → exit 1"                              1 "failures=1"   "$COUNT" "$R"
check "a failure outranks a missing suite → exit 1"     1 ""             "$COUNT" "$R" integrationTest boundedHeapTest
rm "$R/build/test-results/integrationTest/TEST-F.xml"
suite "$R/build/test-results/integrationTest" G 2 0 0 2 2026-09-24T17:07:00.000Z
check "an error → exit 1"                               1 "errors=2"     "$COUNT" "$R" integrationTest
check "no reports anywhere → exit 3"                    3 ""             "$COUNT" "$T/real/IS2"
check "no args → usage"                                 2 ""             "$COUNT"
check "missing directory → usage"                       2 ""             "$COUNT" "$T/nope"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
