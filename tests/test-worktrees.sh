#!/usr/bin/env bash
# worktrees mode: the count, the two levels, and the merge-base.
#
# The headline invariant is that the number on the left agrees with what the
# preview on the right shows. It did not: the count included untracked files
# and the preview did not, so a worktree could say "2 files" and show one.
set -u
. "$(dirname "$0")/lib.sh"

d="$(new_repo)"; s=""
# The worktree lives OUTSIDE the repository. Put it inside and every later
# `git add -A` in the main checkout tries to add it as an embedded repo, which
# buries the test output in hints and would eventually commit a gitlink.
wt="$(mktemp -d "${TMPDIR:-/tmp}/preen-wt.XXXXXX")/w"
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set, which
# is what was cleaning that up.
trap 'rm -rf "$d" "$s" "$(dirname "$wt")" "${_preen_dep_shim:-}"' EXIT

git -C "$d" worktree add -q -b feat "$wt" 2>/dev/null

# One of each kind a worktree can carry.
printf 'committed\n' >> "$wt/f.txt"
tgit -C "$wt" commit -qam "work on the branch"
printf 'uncommitted\n' >> "$wt/f.txt"
printf 'brand new\n' > "$wt/untracked.txt"

base="$(git -C "$wt" merge-base main HEAD)"

# ---- the count --------------------------------------------------------------
# Taken from preen's own worktree list, not rebuilt from git here: a test that
# re-runs the git commands grades its own copy of them and keeps passing after
# bin/preen changes underneath it.
count="$(preen_list "$d" worktrees | head -n 1 | awk '{print $1}')"
assert_eq "$count" "2" "count covers f.txt, committed and uncommitted, plus the untracked file"

# ---- level one: the preview has to show every file the count counted --------
s="$(preen_state wt sbs "" "")"
out="$(preview "$s" "$wt")"

assert_contains "$out" "f.txt"         "level-one preview shows the tracked file"
assert_contains "$out" "untracked.txt" "level-one preview shows the untracked file"
assert_contains "$out" "brand new"     "level-one preview shows untracked content"

shown="$(printf '%s' "$out" | grep -oE '(f|untracked)\.txt' | sort -u | wc -l | tr -d ' ')"
assert_eq "$shown" "$count" "count and level-one preview agree"

# The header names what it is measured against, which is the claim the docs
# make about merge-base rather than the branch tip.
assert_contains "$out" "merge-base with" "preview names the base it used"
assert_contains "$out" "work on the branch" "preview lists the commits on the branch"

# ---- merge-base, not the tip ------------------------------------------------
# Move main on. A tip comparison would drag this file into the worktree's diff;
# a merge-base comparison must not.
printf 'landed on main after the branch\n' > "$d/main-only.txt"
tgit -C "$d" add -A; tgit -C "$d" commit -qm "main moves on"

out="$(preview "$s" "$wt")"
assert_not_contains "$out" "main-only.txt" "a later commit on main stays out of the diff"

count2="$(preen_list "$d" worktrees | head -n 1 | awk '{print $1}')"
assert_eq "$count2" "2" "count is unchanged by main moving on"

# ---- the main checkout is not in the list -----------------------------------
# git lists it first; preen drops that record on purpose.
listed="$(preen_list "$d" worktrees | grep -c 'wt' || true)"
assert_eq "$listed" "1" "only the worktree is listed, not the main checkout"

# ---- read-only --------------------------------------------------------------
# The loudest claim the docs make about this mode.
before_wt="$(snapshot "$wt")"; before_main="$(snapshot "$d")"
preview "$s" "$wt" >/dev/null
PREEN_STATE="$s" "$PREEN" --show "$wt" >/dev/null 2>&1 || true
after_wt="$(snapshot "$wt")"; after_main="$(snapshot "$d")"

assert_eq "$after_wt"   "$before_wt"   "worktrees mode wrote nothing in the worktree"
assert_eq "$after_main" "$before_main" "worktrees mode wrote nothing in the main checkout"

# ---- git older than 2.36 ------------------------------------------------------
# `worktree list --porcelain -z` arrived in git 2.36, and preen reshapes the
# plain form when it is missing. Nothing here has an old git, so take the flag
# away instead: a wrapper first on PATH that refuses -z on that one command and
# passes everything else through. Without the fallback this mode dies with
# "no worktrees besides the main checkout", which is the wrong answer, not a
# smaller one.
oldgit="$(mktemp -d "${TMPDIR:-/tmp}/preen-oldgit.XXXXXX")"
cat > "$oldgit/git" <<'GITEOF'
#!/bin/sh
real="$(PATH="$(echo "$PATH" | sed "s|[^:]*preen-oldgit[^:]*:||g")" command -v git)"
if [ "$1" = worktree ] && [ "$2" = list ]; then
  for a in "$@"; do
    [ "$a" = "-z" ] && { echo "error: unknown option \`z'" >&2; exit 129; }
  done
fi
exec "$real" "$@"
GITEOF
chmod +x "$oldgit/git"

PATH="$oldgit:$PATH" git worktree list --porcelain -z >/dev/null 2>&1
assert_eq "$?" "129" "the fixture really does refuse -z, the way git 2.35 would"

fallback="$(PATH="$oldgit:$PATH" preen_list "$d" worktrees)"
assert_eq "$(printf '%s\n' "$fallback" | grep -c 'feat')" "1" \
  "the pre-2.36 fallback still lists the worktree"
assert_eq "$(printf '%s\n' "$fallback" | head -n 1 | awk '{print $1}')" "2" \
  "and still counts its files"
rm -rf "$oldgit"

# ---- a repo with no worktrees says so ---------------------------------------
bare="$(new_repo)"
out="$(cd "$bare" && "$PREEN" worktrees 2>&1 || true)"
assert_contains "$out" "no worktrees" "a repo with no worktrees explains itself"
rm -rf "$bare"
