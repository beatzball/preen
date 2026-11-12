#!/usr/bin/env bash
# scripts/check-prod-drift.sh: notice a deploy that should have happened and
# did not (#40, #43).
#
# The check runs on a schedule against production, so the only time it acts is
# when nobody is looking. That makes it the kind of guard that has to be
# watched failing here: one throwaway history, and a stand-in production that
# is a version.json on disk, read through curl's file:// support -- the same
# curl call the script makes against preening.dev.
#
# The history, oldest first. Committer dates are pinned so "how long has this
# been undeployed" has one answer.
#
#   s1   site/   t0          the first site
#   b1   bin/    t0 + 1h     a script change: never deploys
#   s2   site/   t0 + 2h     a site change
#   b2   bin/    t0 + 3h     another script change      <- main's HEAD
#   x1   site/   (side branch off s1, never merged)
set -u
. "$(dirname "$0")/lib.sh"

CHECK="$PREEN_ROOT/scripts/check-prod-drift.sh"

root=""
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set, which is
# what was cleaning that up.
trap 'rm -rf ${root:+"$root"} "${_preen_dep_shim:-}"' EXIT
mktmpd root preen-drift
repo="$root/repo"
prod="$root/prod"
mkdir -p "$repo" "$prod"

t0=1700000000
commit_at() {
  # commit_at <epoch> <path> <message>
  mkdir -p "$repo/$(dirname "$2")"
  printf '%s\n' "$3" >> "$repo/$2"
  tgit -C "$repo" add -A
  GIT_COMMITTER_DATE="@$1 +0000" GIT_AUTHOR_DATE="@$1 +0000" \
    tgit -C "$repo" commit -qm "$3"
  git -C "$repo" rev-parse HEAD
}

git init -q -b main "$repo"
s1=$(commit_at "$t0" site/index.md "first site")
b1=$(commit_at $((t0 + 3600)) bin/preen "script change")
s2=$(commit_at $((t0 + 7200)) site/index.md "site change")
b2=$(commit_at $((t0 + 10800)) bin/preen "another script change")
git -C "$repo" checkout -q -b side "$s1"
x1=$(commit_at $((t0 + 3600)) site/index.md "never merged")
git -C "$repo" checkout -q main

serve() { printf '{"commit":"%s"}\n' "$1" > "$prod/version.json"; }

check() {
  # check <now as minutes after s2 landed> -> sets rc and out (stdout+stderr)
  out=$(cd "$repo" && PREEN_NOW=$((t0 + 7200 + $1 * 60)) PREEN_PROBE_RETRIES=1 \
        PREEN_PROBE_DELAY=0 PREEN_DRIFT_GRACE_MIN=120 "$CHECK" "file://$prod" 2>&1)
  rc=$?
}

# CI calls it by path, not through sh.
[ -x "$CHECK" ]; assert_true $? "the check is executable"

# ---- production has main's site --------------------------------------------
serve "$b2"; check 600
assert_eq "$rc" "0" "production at main's HEAD passes"

# The case the brief warned about: main moved on with a bin/-only commit, which
# never deploys. Production is behind HEAD and that is correct.
serve "$s2"; check 600
assert_eq "$rc" "0" "production at the last site/ commit passes, though HEAD is later"
assert_contains "$out" "production has main's site/" "...and says what it compared"

# ---- production is missing a site change ------------------------------------
# #40 exactly: s2 changed site/, its deploy never happened, and b2 then pushed
# green without touching site/.
serve "$b1"; check 600
assert_eq "$rc" "1" "production missing a site/ change for 10 hours fails"
assert_contains "$out" "::error::" "...as an Actions error annotation"
assert_contains "$out" "$(git -C "$repo" rev-parse --short "$s2")" "...naming the commit it is missing"

# Inside the grace period the deploy may simply still be running.
serve "$b1"; check 30
assert_eq "$rc" "0" "a site/ change 30 minutes old is pending, not drift"
assert_contains "$out" "pending" "...and says so"

# The grace is measured from the OLDEST missing change: s2 is old, and a fresh
# site change on top of it must not reset the clock.
commit_at $((t0 + 7200 + 590 * 60)) site/index.md "fresh site change" >/dev/null
serve "$b1"; check 600
assert_eq "$rc" "1" "an old missed change still fails when a fresh one lands on top"
git -C "$repo" reset -q --hard "$b2"

# ---- production is serving something main does not have ---------------------
serve "$x1"; check 600
assert_eq "$rc" "1" "production built from a commit that is not on main fails"
assert_contains "$out" "not on main's history" "...and says why"

serve "0123456789abcdef0123456789abcdef01234567"; check 600
assert_eq "$rc" "1" "production at a commit this checkout has never seen fails"

# ---- production does not say what it serves ---------------------------------
printf '{"commit":"unknown"}\n' > "$prod/version.json"; check 600
assert_eq "$rc" "1" "an image built without GIT_SHA fails, not passes"
assert_contains "$out" "gave no commit" "...and says so"

rm -f "$prod/version.json"; check 600
assert_eq "$rc" "1" "no version.json at all fails"

