#!/usr/bin/env bash
# worktrees mode: the count, the two levels, and the merge-base.
#
# The headline invariant is that the number on the left agrees with what the
# preview on the right shows. It did not: the count included untracked files
# and the preview did not, so a worktree could say "2 files" and show one.
set -u
. "$(dirname "$0")/lib.sh"

d="$(new_repo)" || exit 1; s=""
# The worktree lives OUTSIDE the repository. Put it inside and every later
# `git add -A` in the main checkout tries to add it as an embedded repo, which
# buries the test output in hints and would eventually commit a gitlink.
mktmpd wtbox preen-wt
wt="$wtbox/w"
# Everything the file makes later, named here so the trap owns it. An inline
# `rm` at the end of a section cleans up only when the file reaches the end;
# a `set -u` abort halfway through used to leave these behind.
oldgit=""; nofzf=""; nlonly=""; nlroot=""; leadwt=""
stale=""; stonly=""; storoot=""; scen=""; scraw=""
rawnl=""; rawnl2=""; rawlead=""; rawst=""
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set, which
# is what was cleaning that up.
cleanup() {
  # Every path is guarded with ${x:+...}, so an empty one contributes nothing
  # rather than an argument. `$(dirname "$wt")` is gone: with an empty $wt that
  # is `dirname ""`, which answers `.` — the checkout.
  rm -rf ${d:+"$d"} ${s:+"$s"} ${wtbox:+"$wtbox"} "${_preen_dep_shim:-}" \
         ${oldgit:+"$oldgit"} ${nofzf:+"$nofzf"} ${nlonly:+"$nlonly"} \
         ${nlroot:+"$nlroot"} ${leadwt:+"$leadwt"} ${stale:+"$stale"} \
         ${stonly:+"$stonly"} ${storoot:+"$storoot"} ${scen:+"$scen"}
  rm -f ${rawnl:+"$rawnl" "$rawnl.argv"} ${rawnl2:+"$rawnl2" "$rawnl2.argv"} \
        ${rawlead:+"$rawlead" "$rawlead.argv"} ${rawst:+"$rawst" "$rawst.argv"} \
        ${scraw:+"$scraw" "$scraw.argv"}
}
trap cleanup EXIT

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
s="$(preen_state wt sbs "" "")" || exit 1
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
mktmpd oldgit preen-oldgit
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
nlwt="$wtbox/two"$'\n'"lines"
git -C "$d" worktree add -q -b nl "$nlwt" 2>/dev/null
printf 'x\n' > "$nlwt/new.txt"

# Every record is `label <US> absolute-path`, and the path is what the preview
# and ctrl-e are spent on. This asks the one question the wrong entry failed:
# is it there?
#
# The separator is read out of the flags preen passed rather than written down
# here. Hard-coding it made a change to `WT_SEP` turn THIS assertion red, which
# sent the reader looking for an old-git bug that was not there.
#
# Two guards, neither decoration: the count, because an empty list would
# otherwise satisfy a loop that never ran, and `|| [ -n "$rec" ]`, because a
# final record with no trailing NUL would otherwise be skipped — the partial
# record from #19.
# "Is it a directory" is not the whole question, and asking only that is the
# mistake this file exists to hold shut on both sides. A path cut short can
# land on a real directory — the worktree's own parent — so every listed path
# must also carry the `.git` entry that makes a directory a worktree.
wt_paths_all_real() {
  local raw="$1" sep rec dir n=0
  sep="$(list_flags "$raw" | sed -n 's/^--delimiter=//p')"
  [ -n "$sep" ] || return 1
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    dir="${rec#*"$sep"}"
    [ -d "$dir" ] || return 1
    [ -e "$dir/.git" ] || return 1
    n=$((n + 1)); rec=""
  done < "$raw"
  [ "$n" -gt 0 ]
}

# Three checks below run preen all the way to the picker rather than to a
# callback, which nothing else in the suite does. They need a stand-in fzf:
# preen is meant to die or to come straight back here, and the day it does not,
# the real fzf would open a terminal and the suite would hang instead of fail.
mktmpd nofzf preen-nofzf
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$nofzf/fzf"
chmod +x "$nofzf/fzf"

mktmpf rawnl preen-nl
PATH="$oldgit:$PATH" preen_list_raw "$rawnl" "$d" worktrees

wt_paths_all_real "$rawnl"
assert_true $? "the pre-2.36 fallback lists no worktree whose path is not a worktree"
assert_eq "$(list_count "$rawnl")" "1" \
  "the reachable worktree is still listed — only the unreachable one went"
# The reason, not just the count. The note's whole point is why the worktree
# went, and an assertion on "hidden" alone stayed green when the reason text was
# replaced with nonsense.
assert_contains "$(list_flags "$rawnl")" "not there" \
  "the picker header says a worktree git listed is not there"
assert_contains "$(list_flags "$rawnl")" "2.36" \
  "and on the fallback it names the git version, which is the reason there"

# When the unreachable one is the ONLY worktree there is, "no worktrees besides
# the main checkout" is the same lie in a different place.
nlonly="$(new_repo)" || exit 1
mktmpd nlroot preen-nlonly
# Resolved, because the assertion below compares preen's idea of the path with
# this one's. git prints the real path, and on macOS $TMPDIR is a symlink into
# /private/var, so the two spellings differ.
#
# Through resolve_dir, never `nlroot="$(cd "$nlroot" && pwd -P)"`. That line is
# what deleted this checkout's tests/ directory: `cd ""` does not fail, it stays
# put, so an empty $nlroot came back as the suite's own cwd and the trap above
# removed it.
resolve_dir nlroot
git -C "$nlonly" worktree add -q -b solo "$nlroot/two"$'\n'"lines" 2>/dev/null
out="$(cd "$nlonly" && PATH="$oldgit:$nofzf:$PATH" "$PREEN" worktrees 2>&1 </dev/null || true)"
assert_contains "$out" "not there" \
  "with only the unreachable worktree, preen says it was dropped"
assert_not_contains "$out" "no worktrees besides" \
  "and does not claim the repository had none to begin with"
assert_contains "$out" "$nlroot" \
  "and names the path, which stderr has the width for even though the header does not"

# ---- a newline that STARTS the last component, still on the old git ----------
# The cut path is then the worktree's PARENT, which is a real directory — so
# "is it a directory" passes and preen listed the parent as a worktree, showing
# the main checkout's branch and the main checkout's files. A worktree always
# carries a `.git` entry and a bare parent does not, which is the question the
# fallback asks instead.
mktmpd leadwt preen-lead
git -C "$d" worktree add -q -b lead "$leadwt/"$'\n'"nl" 2>/dev/null
printf 'x\n' > "$leadwt/"$'\n'"nl/new.txt"

mktmpf rawlead preen-lead-raw
PATH="$oldgit:$PATH" preen_list_raw "$rawlead" "$d" worktrees
assert_eq "$(list_count "$rawlead")" "1" \
  "the fallback lists only the reachable worktree, not the cut path's parent"
wt_paths_all_real "$rawlead"
assert_true $? "and the path it does list carries the .git a worktree has"
git -C "$d" worktree remove --force "$leadwt/"$'\n'"nl" 2>/dev/null

# ---- and none of that may cost anything on git 2.36+ ------------------------
# The drop above is the fallback's answer, not preen's. On a git with -z the
# same worktree is reachable, so it has to be listed and nothing may be hidden.
# `-C "$d"`, not the suite's own cwd: run from a directory that is not a
# repository this probe fails for a reason that has nothing to do with the git
# version, and the label would then be a lie. $d is the fixture, and always a
# repository.
git -C "$d" worktree list --porcelain -z >/dev/null 2>&1
assert_true $? "this git has 'worktree list -z', so the 2.36+ path is reachable here"

mktmpf rawnl2 preen-nl2
preen_list_raw "$rawnl2" "$d" worktrees
assert_eq "$(list_count "$rawnl2")" "2" \
  "on git 2.36+ the newline-named worktree is listed alongside the other"
assert_not_contains "$(list_flags "$rawnl2")" "not there" \
  "and nothing is reported dropped"

# ---- a worktree whose directory was deleted by hand, on THIS git -------------
# The state a repository is actually found in: `rm -rf` of a worktree without a
# `git worktree prune`. git keeps the record and marks it prunable, so the path
# it prints is not a directory — on every version of git, with no newline
# anywhere near it.
#
# Dropping the row is right; blaming the git version for it is not. The first
# version of this check keyed on "not a directory" alone and told the reader
# that a newline needed git 2.36. On git 2.50 both halves of that are false, and
# it hid the one thing that would have helped: prune.
mktmpd stale preen-stale
git -C "$d" worktree add -q -b stale "$stale/gone" 2>/dev/null
rm -rf "$stale/gone"
git -C "$d" worktree list --porcelain | grep -q '^prunable'
assert_true $? "the fixture really is a worktree git still lists but cannot find"

mktmpf rawst preen-stale-raw
preen_list_raw "$rawst" "$d" worktrees
wt_paths_all_real "$rawst"
assert_true $? "a deleted worktree is not listed, and what is listed is there"
assert_eq "$(list_count "$rawst")" "2" \
  "the two live worktrees are still listed beside it"
assert_contains "$(list_flags "$rawst")" "worktree prune" \
  "the header names prune, which is the fix on a git that has -z"
assert_not_contains "$(list_flags "$rawst")" "2.36" \
  "and does not blame the git version, which has nothing to do with it"
assert_not_contains "$(list_flags "$rawst")" "newline" \
  "nor a newline, which is nowhere in this fixture"

# The same, when the deleted worktree is the only one the repository has: the
# message is the whole output, and preen exits on it.
stonly="$(new_repo)" || exit 1
mktmpd storoot preen-stonly
git -C "$stonly" worktree add -q -b solo "$storoot/gone" 2>/dev/null
rm -rf "$storoot/gone"
out="$(cd "$stonly" && PATH="$nofzf:$PATH" "$PREEN" worktrees 2>&1 </dev/null || true)"
assert_contains     "$out" "worktree prune" "with only a deleted worktree, preen says to prune"
assert_not_contains "$out" "2.36"           "and still does not blame the git version"
assert_not_contains "$out" "no worktrees besides" \
  "and still does not claim the repository had none"

# Two at once, because the plural was never exercised: every fixture above drops
# exactly one, so `1 worktree ... is` could have been hard-coded and stayed green.
git -C "$stonly" worktree add -q -b solo2 "$storoot/gone2" 2>/dev/null
rm -rf "$storoot/gone2"
out="$(cd "$stonly" && PATH="$nofzf:$PATH" "$PREEN" worktrees 2>&1 </dev/null || true)"
assert_contains "$out" "2 worktrees git listed are not there" \
  "two dropped worktrees are counted and worded as two"

git -C "$d" worktree prune

# ---- on the fallback, a cut path that lands on something REAL ----------------
# The `.git` test asks whether the path is a worktree, so it passes whenever the
# cut lands on one — and then nothing notices. Three shapes do that, and each is
# something git cannot have printed: a trailing slash, the root itself, and a
# path already listed. Without those checks preen showed a duplicate row, or the
# outer worktree twice, or the main checkout, and said nothing about any of it.
mktmpd scen preen-scen
scen_run() {
  # scen_run <repo> -> fills $screc with the list and $scnote with the note
  mktmpf scraw preen-scen-raw
  PATH="$oldgit:$PATH" preen_list_raw "$scraw" "$1" worktrees
  screc="$(tr '\0' '\n' < "$scraw")"
  scnote="$(list_flags "$scraw" | grep 'not there' || true)"
  sccount="$(list_count "$scraw")"
  rm -f "$scraw" "$scraw.argv"
}
screc=""; scnote=""; sccount=""

# a worktree nested inside another, the newline starting the last component:
# the cut leaves the OUTER worktree, which is real and has a .git
sc1="$scen/nested"
git init -q -b main "$sc1"; printf 'b\n' > "$sc1/f.txt"
tgit -C "$sc1" add -A; tgit -C "$sc1" commit -qm i
git -C "$sc1" worktree add -q -b sc-outer "$sc1/outer" 2>/dev/null
git -C "$sc1" worktree add -q -b sc-nl "$sc1/outer/"$'\n'"nl" 2>/dev/null
scen_run "$sc1"
assert_eq "$sccount" "1" "a worktree nested in another is not listed twice when the path is cut"
assert_contains "$scnote" "not there" "and the one it could not name is reported"

# `wts/a` and `wts/a<newline>b`: the second cuts to exactly the first
sc2="$scen/prefix"
git init -q -b main "$sc2"; printf 'b\n' > "$sc2/f.txt"
tgit -C "$sc2" add -A; tgit -C "$sc2" commit -qm i
git -C "$sc2" worktree add -q -b sc-a "$sc2/wts/a" 2>/dev/null
git -C "$sc2" worktree add -q -b sc-ab "$sc2/wts/a"$'\n'"b" 2>/dev/null
scen_run "$sc2"
assert_eq "$sccount" "1" "a cut path equal to one already listed is not listed again"
assert_contains "$scnote" "not there" "and that one is reported too"

# a worktree directly inside the main checkout: the cut leaves the root
sc3="$scen/inmain"
git init -q -b main "$sc3"; printf 'b\n' > "$sc3/f.txt"
tgit -C "$sc3" add -A; tgit -C "$sc3" commit -qm i
git -C "$sc3" worktree add -q -b sc-nl2 "$sc3/"$'\n'"nl" 2>/dev/null
git -C "$sc3" worktree add -q -b sc-ok "$sc3/ok" 2>/dev/null
scen_run "$sc3"
assert_eq "$sccount" "1" "a cut path equal to the main checkout is not listed as a worktree"
assert_contains "$scnote" "not there" "and it is reported rather than dropped in silence"
# There was a third assertion here, that the row carried no `sc-nl2`. It passed
# with the check removed as well: the row the bug makes is the ROOT's, so it
# shows the root's branch and never that name. Two assertions that go red beat
# three where one is cover.

# Each of the three checks needs a fixture that REACHES it. sc3 above cuts to
# `<root>/`, which the trailing-slash check refuses first — so with only these
# fixtures the root check and the `.git` check could both be deleted and the
# suite stayed green. Two more, each shaped to get past the checks before it.

# the root check: a worktree that is a SIBLING of the root, so the cut is the
# root exactly, with no trailing slash to catch it first
sc4="$scen/rootexact"
git init -q -b main "$sc4"; printf 'b\n' > "$sc4/f.txt"
tgit -C "$sc4" add -A; tgit -C "$sc4" commit -qm i
git -C "$sc4" worktree add -q -b sc-sib "$sc4"$'\n'"x" 2>/dev/null
git -C "$sc4" worktree add -q -b sc-ok4 "$sc4/ok" 2>/dev/null
scen_run "$sc4"
assert_eq "$sccount" "1" \
  "a cut path that IS the root, with no trailing slash, is not listed as a worktree"
assert_contains "$scnote" "not there" "and is reported"

# the .git check: the cut lands on a plain directory — no trailing slash, not the
# root, not already listed, and not a worktree either
sc5="$scen/plaindir"
git init -q -b main "$sc5"; printf 'b\n' > "$sc5/f.txt"
tgit -C "$sc5" add -A; tgit -C "$sc5" commit -qm i
mkdir -p "$sc5/wts/x"
git -C "$sc5" worktree add -q -b sc-py "$sc5/wts/x"$'\n'"y" 2>/dev/null
git -C "$sc5" worktree add -q -b sc-ok5 "$sc5/ok" 2>/dev/null
scen_run "$sc5"
assert_eq "$sccount" "1" \
  "a cut path that is a plain directory, not a worktree, is not listed as one"
assert_contains "$scnote" "not there" "and is reported too"

# The note is looked up on every run, and on almost every run there is nothing
# to report. Reading a file that is not there is the ordinary case, so it has to
# be silent: preen's stderr is the user's terminal, and the picker is about to
# be drawn over it. Every test above throws preen's stderr away, which is
# exactly how a leak like this survives one.
quiet="$(cd "$d" && PATH="$nofzf:$PATH" "$PREEN" worktrees 2>&1 >/dev/null </dev/null || true)"
assert_eq "$quiet" "" "a worktrees run with nothing to report writes nothing to stderr"

git -C "$d" worktree remove --force "$nlwt" 2>/dev/null

# ---- a repo with no worktrees says so ---------------------------------------
bare="$(new_repo)" || exit 1
out="$(cd "$bare" && "$PREEN" worktrees 2>&1 || true)"
assert_contains "$out" "no worktrees" "a repo with no worktrees explains itself"
rm -rf "$bare"
