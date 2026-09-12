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

# ---- a newline in a worktree's own directory name, on that same old git ------
# `worktree list --porcelain` puts each path on its own line, so on the
# fallback a directory name holding a newline is indistinguishable from two
# records and the path arrives cut short at it. What preen listed was not a
# missing entry but a plausible wrong one — "0 files  detached  <prefix>", the
# right shape and wrong in every field, previewing and opening nothing.
#
# It is out of reach on that git, so the entry is dropped and the picker's
# header says how many went. The header, because fzf takes the whole screen and
# anything on stderr before it starts is painted over.
nlwt="$(dirname "$wt")/two"$'\n'"lines"
git -C "$d" worktree add -q -b nl "$nlwt" 2>/dev/null
printf 'x\n' > "$nlwt/new.txt"

# Every record is `label <US> absolute-path`, and the path is what the preview
# and ctrl-e are spent on. This asks the one question the wrong entry failed:
# is it there? The count guard is not decoration — an empty list would
# otherwise satisfy a loop that never ran.
US="$(printf '\037')"
wt_paths_all_exist() {
  local rec dir n=0
  while IFS= read -r -d '' rec; do
    dir="${rec#*"$US"}"
    [ -d "$dir" ] || return 1
    n=$((n + 1))
  done < "$1"
  [ "$n" -gt 0 ]
}

# The two checks below run preen all the way to the picker rather than to a
# callback, which nothing else in the suite does. They need a stand-in fzf:
# preen is meant to die or to come straight back here, and the day it does not,
# the real fzf would open a terminal and the suite would hang instead of fail.
nofzf="$(mktemp -d "${TMPDIR:-/tmp}/preen-nofzf.XXXXXX")"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$nofzf/fzf"
chmod +x "$nofzf/fzf"

rawnl="$(mktemp "${TMPDIR:-/tmp}/preen-nl.XXXXXX")"
PATH="$oldgit:$PATH" preen_list_raw "$rawnl" "$d" worktrees

wt_paths_all_exist "$rawnl"
assert_true $? "the pre-2.36 fallback lists no worktree whose path does not exist"
assert_eq "$(list_count "$rawnl")" "1" \
  "the reachable worktree is still listed — only the unreachable one went"
assert_contains "$(list_flags "$rawnl")" "1 worktree hidden" \
  "the picker header says one worktree was dropped, and why"

# When the unreachable one is the ONLY worktree there is, "no worktrees besides
# the main checkout" is the same lie in a different place.
nlonly="$(new_repo)"
nlroot="$(mktemp -d "${TMPDIR:-/tmp}/preen-nlonly.XXXXXX")"
git -C "$nlonly" worktree add -q -b solo "$nlroot/two"$'\n'"lines" 2>/dev/null
out="$(cd "$nlonly" && PATH="$oldgit:$nofzf:$PATH" "$PREEN" worktrees 2>&1 </dev/null || true)"
assert_contains "$out" "hidden" \
  "with only the unreachable worktree, preen says it was dropped"
assert_not_contains "$out" "no worktrees besides" \
  "and does not claim the repository had none to begin with"
rm -rf "$nlonly" "$nlroot"
rm -rf "$oldgit"

# ---- and none of that may cost anything on git 2.36+ ------------------------
# The drop above is the fallback's answer, not preen's. On a git with -z the
# same worktree is reachable, so it has to be listed and nothing may be hidden.
git worktree list --porcelain -z >/dev/null 2>&1
assert_true $? "this git has 'worktree list -z', so the 2.36+ path is reachable here"

rawnl2="$(mktemp "${TMPDIR:-/tmp}/preen-nl2.XXXXXX")"
preen_list_raw "$rawnl2" "$d" worktrees
assert_eq "$(list_count "$rawnl2")" "2" \
  "on git 2.36+ the newline-named worktree is listed alongside the other"
assert_not_contains "$(list_flags "$rawnl2")" "hidden" \
  "and nothing is reported dropped"

# The note is looked up on every run, and on almost every run there is nothing
# to report. Reading a file that is not there is the ordinary case, so it has to
# be silent: preen's stderr is the user's terminal, and the picker is about to
# be drawn over it. Every test above throws preen's stderr away, which is
# exactly how a leak like this survives one.
quiet="$(cd "$d" && PATH="$nofzf:$PATH" "$PREEN" worktrees 2>&1 >/dev/null </dev/null || true)"
assert_eq "$quiet" "" "a worktrees run with nothing to report writes nothing to stderr"

git -C "$d" worktree remove --force "$nlwt" 2>/dev/null
rm -f "$rawnl" "$rawnl.argv" "$rawnl2" "$rawnl2.argv"; rm -rf "$nofzf"

# ---- a repo with no worktrees says so ---------------------------------------
bare="$(new_repo)"
out="$(cd "$bare" && "$PREEN" worktrees 2>&1 || true)"
assert_contains "$out" "no worktrees" "a repo with no worktrees explains itself"
rm -rf "$bare"
