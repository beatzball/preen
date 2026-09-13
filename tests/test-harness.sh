#!/usr/bin/env bash
# The suite must not be able to touch the checkout it is testing.
#
# Everything else in tests/ grades bin/preen. This file grades the harness, for
# one reason: it has twice done real damage, and both times from nothing more
# exotic than a $TMPDIR that no longer existed.
#
#   - `mktemp` fails, so a variable is empty. A trap then runs
#     `rm -rf "$(cd "$empty" && pwd -P)"` — and `cd ""` does not fail, it stays
#     put — so the suite deleted its own tests/ directory. Nine files.
#   - `mktemp` fails inside new_repo, so `git -C "" add -A; git -C "" commit`
#     staged the working directory and committed it to the live branch.
#
# Both are the same shape: an unchecked path reaching `rm -rf`, `cd` or
# `git -C`. So this file runs every other test file against a broken TMPDIR, in
# a throwaway copy that is a git repository, and asserts the copy comes back
# untouched. It does not care which file misbehaves or how — only that none can.
set -u
. "$(dirname "$0")/lib.sh"

box=""; broken=""
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set, which is
# what was cleaning that up. Leaving it out is how this file leaked a directory
# per run.
cleanup() { rm -rf ${box:+"$box"} ${broken:+"$broken"} "${_preen_dep_shim:-}"; }
trap cleanup EXIT

# This file's own temporary paths go through the same guard as everyone's, so a
# broken TMPDIR here fails loudly rather than turning this test destructive in
# its turn.
mktmpd box preen-harness

# A TMPDIR that does not exist, which is what makes mktemp fail. Named inside a
# directory that does exist, so nothing outside $box is ever a candidate.
broken="$box/no-such-tmpdir"

copy="$box/checkout"
mkdir -p "$copy"
( cd "$PREEN_ROOT" && tar -cf - bin tests ) | tar -x -C "$copy"

# A repository, so a stray `git -C ""` has something to damage and is visible
# when it does. One commit, and a dirty file that must survive: uncommitted work
# in tests/ is exactly what the rm -rf destroyed.
git init -q -b main "$copy"
printf 'uncommitted work nobody wants deleted\n' > "$copy/tests/scratch.txt"
tgit -C "$copy" add -A
tgit -C "$copy" commit -qm baseline
printf 'edited after the commit\n' >> "$copy/tests/scratch.txt"

files_before="$(find "$copy/bin" "$copy/tests" -type f | LC_ALL=C sort)"
head_before="$(git -C "$copy" rev-parse HEAD)"
n_before="$(git -C "$copy" rev-list --count HEAD)"
dirty_before="$(cat "$copy/tests/scratch.txt")"

# Every test file, one at a time, the way run.sh invokes them. test-harness.sh
# is skipped: it is this file, and running it here would recurse.
ran=0
for t in "$copy"/tests/test-*.sh; do
  case "${t##*/}" in test-harness.sh) continue ;; esac
  ran=$((ran + 1))
  ( cd "$copy/tests" && TMPDIR="$broken" bash "$t" </dev/null >/dev/null 2>&1 )
done

# Not decoration: with the glob unmatched or the skip too broad this loop would
# run nothing and every assertion below would pass on an untouched copy.
[ "$ran" -ge 5 ]
assert_true $? "every test file was run against the broken TMPDIR ($ran of them)"

files_after="$(find "$copy/bin" "$copy/tests" -type f 2>/dev/null | LC_ALL=C sort)"
assert_eq "$files_after" "$files_before" \
  "a broken TMPDIR deletes nothing in the checkout the suite runs from"

assert_eq "$(cat "$copy/tests/scratch.txt" 2>/dev/null)" "$dirty_before" \
  "and leaves uncommitted work in tests/ exactly as it was"

assert_eq "$(git -C "$copy" rev-list --count HEAD 2>/dev/null)" "$n_before" \
  "and commits nothing to the branch the checkout is on"
assert_eq "$(git -C "$copy" rev-parse HEAD 2>/dev/null)" "$head_before" \
  "and leaves HEAD where it was"
assert_eq "$(git -C "$copy" status --porcelain 2>/dev/null)" " M tests/scratch.txt" \
  "and stages nothing — the one dirty file is still the only change"

# The failure has to be loud as well as harmless. A suite that quietly does
# nothing is how a broken TMPDIR goes unnoticed until it is destructive.
( cd "$copy/tests" && TMPDIR="$broken" bash test-worktrees.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "a test file given a broken TMPDIR exits non-zero rather than carrying on"

out="$( cd "$copy/tests" && TMPDIR="$broken" bash test-worktrees.sh </dev/null 2>&1 )"
assert_contains "$out" "no temporary" "and says what it could not get"
assert_contains "$out" "$broken"      "and names the TMPDIR it was given"

# run.sh has to fail the run too, not just the file.
( cd "$copy" && TMPDIR="$broken" tests/run.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "run.sh fails the whole run when TMPDIR is unusable"
