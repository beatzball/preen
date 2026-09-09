#!/usr/bin/env bash
# Run every tests/test-*.sh and sum results.
#
#   tests/run.sh              # everything
#   tests/run.sh diff         # only files whose name contains "diff"
set -u
cd "$(dirname "$0")"

filter="${1:-}"
pass=0 fail=0
crashed=""

for t in test-*.sh; do
  [ -e "$t" ] || continue
  case "$t" in *"$filter"*) ;; *) continue ;; esac

  printf '\n== %s ==\n' "$t"
  out="$(PREEN_TESTS_PASS=0 PREEN_TESTS_FAIL=0 bash "$t" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  pass=$((pass + $(printf '%s' "$out" | grep -c '^  PASS')))
  fail=$((fail + $(printf '%s' "$out" | grep -c '^  FAIL')))

  # PASS/FAIL counts say nothing about a file that died partway — a syntax
  # error or an unexpected `set -e` abort just contributes fewer PASS lines and
  # no FAIL lines, so the totals would silently under-report and this script
  # could still exit 0. Test files exit 0 when they finish, so a non-zero exit
  # is something no line accounts for: name it and fail the run.
  if [ "$rc" -ne 0 ]; then
    printf 'RUNNER: %s exited %d before finishing — treating the run as failed\n' "$t" "$rc"
    crashed="$crashed $t"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ -n "$crashed" ] && printf 'RUNNER: died mid-run:%s\n' "$crashed"

# Zero tests is not success. A bad filter, or a rename that breaks the glob,
# would otherwise report "0 passed, 0 failed" and exit clean.
if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
  printf 'RUNNER: no tests ran%s\n' "${filter:+ (filter: $filter)}"
  exit 1
fi

[ "$fail" -eq 0 ] && [ -z "$crashed" ]
