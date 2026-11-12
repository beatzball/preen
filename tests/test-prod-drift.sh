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
  # check <now as minutes after s2 landed> [dir] [remote] -> sets rc and out
  # Runs in <dir> (default: the repo), with PREEN_DRIFT_REMOTE=<remote> if
  # given. stdout and stderr together.
  out=$(cd "${2:-$repo}" && PREEN_NOW=$((t0 + 7200 + $1 * 60)) PREEN_PROBE_RETRIES=1 \
        PREEN_PROBE_DELAY=0 PREEN_DRIFT_GRACE_MIN=120 PREEN_DRIFT_REMOTE="${3:-}" \
        "$CHECK" "file://$prod" 2>&1)
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

# But a change that was REVERTED is not outstanding. Production is at b2; a
# site change lands and is reverted an hour later, so main's site/ matches
# production again; much later a fresh change lands and is deploying. Only the
# fresh one is missing, and it is ten minutes old.
r1=$(commit_at $((t0 + 7200 + 60 * 60)) site/index.md "site change, soon reverted")
GIT_COMMITTER_DATE="@$((t0 + 7200 + 70 * 60)) +0000" tgit -C "$repo" revert --no-edit "$r1" >/dev/null
commit_at $((t0 + 7200 + 590 * 60)) site/new.md "fresh site change" >/dev/null
serve "$b2"; check 600
assert_eq "$rc" "0" "a reverted change does not charge its age to the next deploy"
assert_contains "$out" "pending" "...which is pending, not drift"
git -C "$repo" reset -q --hard "$b2"

# ---- the checkout is older than production ----------------------------------
# A scheduled run checks out main, then waits in a queue; meanwhile main moves
# on and the new commit deploys. Production is then AHEAD of the checkout, and
# that is a healthy deploy, not drift. CI sets PREEN_DRIFT_REMOTE=origin so the
# script reads main again after reading production.
ci="$root/ci"
git clone -q "$repo" "$ci"
n1=$(commit_at $((t0 + 7200 + 595 * 60)) site/index.md "lands after the checkout")
serve "$n1"
check 600 "$ci"
assert_eq "$rc" "1" "without a refetch, production ahead of the checkout looks like drift"
assert_contains "$out" "not in this checkout of main" "...because the checkout has never seen it"
check 600 "$ci" origin
assert_eq "$rc" "0" "with PREEN_DRIFT_REMOTE, main is re-read after production and it passes"
git -C "$repo" reset -q --hard "$b2"

# ---- production is serving something main does not have ---------------------
serve "$x1"; check 600
assert_eq "$rc" "1" "production built from a commit that is not on main fails"
assert_contains "$out" "not on main's history" "...and says why"

serve "0123456789abcdef0123456789abcdef01234567"; check 600
assert_eq "$rc" "1" "production at a commit this checkout has never seen fails"
assert_contains "$out" "not in this checkout of main" "...and says why"

# A short sha would resolve by abbreviation to whatever matches. The image
# bakes the full one, so anything shorter is not trusted.
serve "$(git -C "$repo" rev-parse --short=12 "$b2")"; check 600
assert_eq "$rc" "1" "a version.json with a short sha fails"

# ---- production does not say what it serves ---------------------------------
printf '{"commit":"unknown"}\n' > "$prod/version.json"; check 600
assert_eq "$rc" "1" "an image built without GIT_SHA fails, not passes"
assert_contains "$out" "gave no commit" "...and says so"

rm -f "$prod/version.json"; check 600
assert_eq "$rc" "1" "no version.json at all fails"

