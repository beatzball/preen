#!/usr/bin/env bash
# The file list `preen diff` builds, and the preview of each entry.
#
# The list and the preview have to agree on how a path is spelled. When they
# disagree the list still looks right and every preview comes back blank —
# the shape of two bugs this file exists to hold shut.
#
# The list comes from preen itself, through the fzf shim in lib.sh. Rebuilding
# the same git commands here would grade the copy in this file and keep passing
# after bin/preen changed underneath it.
set -u
. "$(dirname "$0")/lib.sh"

d="$(new_repo)"; s=""; e=""
trap 'rm -rf "$d" "$s" "$e" "${_preen_dep_shim:-}"' EXIT

mkdir -p "$d/sub"
printf 'deep\n' > "$d/sub/deep.txt"
tgit -C "$d" add -A; tgit -C "$d" commit -qm second

# One of each kind the list has to carry: a modified tracked file, and an
# untracked one — the two halves that used to be spelled differently.
printf 'more\n' >> "$d/f.txt"
printf 'new\n'  > "$d/sub/untracked.txt"

want="f.txt sub/untracked.txt "

got="$(preen_list "$d" diff | sort | tr '\n' ' ')"
assert_eq "$got" "$want" "list from the repository root"

# The bug: `git diff --name-only` prints repo-root-relative paths while
# `ls-files --others` printed cwd-relative ones, so from sub/ the list mixed
# "f.txt" with "untracked.txt" and the preview of the first came back empty.
got="$(preen_list "$d/sub" diff | sort | tr '\n' ' ')"
assert_eq "$got" "$want" "list from a subdirectory is identical"

got="$(preen_list "$d/sub" diff | grep -c '^sub/untracked.txt$')"
assert_eq "$got" "1" "untracked path stays repo-root-relative from a subdirectory"

# ---- every entry in the list can actually be opened --------------------------
# A list is only correct if each entry previews. preen runs its preview from
# the repository root, because fzf inherits that cwd.
s="$(preen_state diff sbs "" "")"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  out="$(cd "$d" && preview "$s" "$f")"
  assert_nonempty "$out" "preview renders: $f"
done < <(preen_list "$d" diff)

out="$(cd "$d" && preview "$s" sub/untracked.txt)"
assert_contains "$out" "new" "an untracked file shows its content"

# ---- staged and unstaged together -------------------------------------------
# The docs promise you see the file as it will land, not one half of it.
printf 'staged-change\n' >> "$d/sub/deep.txt"
tgit -C "$d" add sub/deep.txt
printf 'unstaged-change\n' >> "$d/sub/deep.txt"
out="$(cd "$d" && preview "$s" sub/deep.txt)"
assert_contains "$out" "staged-change"   "preview includes the staged half"
assert_contains "$out" "unstaged-change" "preview includes the unstaged half"

# ---- a revision argument ----------------------------------------------------
got="$(preen_list "$d" diff HEAD~1 | tr '\n' ' ')"
assert_contains "$got" "sub/deep.txt" "list against a revision"

# ---- a repository with no commit yet ----------------------------------------
# preen falls back to the index when there is no HEAD. Without that branch it
# dies on `git diff HEAD` rather than showing the staged files.
e="$(mktemp -d "${TMPDIR:-/tmp}/preen-empty.XXXXXX")"
git init -q -b main "$e"
printf 'staged\n' > "$e/a.txt"
git -C "$e" add -A

git -C "$e" rev-parse --verify -q HEAD >/dev/null 2>&1
assert_eq "$?" "1" "the fixture really has no HEAD"

got="$(preen_list "$e" diff | tr '\n' ' ')"
assert_eq "$got" "a.txt " "list in a repository with no commit"

# ---- the list is in order ----------------------------------------------------
# What the picker shows is the order preen hands over. The two halves arrive
# unsorted — every tracked name first, then every untracked one — so this holds
# only because the list is sorted after they are joined, and it is what notices
# a sort that has stopped seeing the entries.
#
# Its own repository, so it cannot disturb the fixture above.
# The names are chosen so that byte order and a collating locale disagree:
# LC_ALL=C puts every capital before every lowercase and sorts punctuation by
# its byte, while en_US.UTF-8 folds case and ignores the leading punctuation.
# So this also fails if the sorts stop pinning the locale, whatever locale the
# person running the suite happens to have.
o_repo="$(new_repo)"
printf 'zz\n' > "$o_repo/zz-tracked.txt"
printf 'zz\n' > "$o_repo/Zebra.txt"
printf 'zz\n' > "$o_repo/_under.txt"
tgit -C "$o_repo" add -A; tgit -C "$o_repo" commit -qm ordering
printf 'more\n' >> "$o_repo/zz-tracked.txt"
printf 'more\n' >> "$o_repo/Zebra.txt"
printf 'more\n' >> "$o_repo/_under.txt"
printf 'new\n'  > "$o_repo/aa-untracked.txt"
printf 'new\n'  > "$o_repo/-dash.txt"

o="$(mktemp "${TMPDIR:-/tmp}/preen-order.XXXXXX")"
preen_list_raw "$o" "$o_repo" diff
assert_eq "$(preen_list "$o_repo" diff | tr '\n' ' ')" \
  "-dash.txt Zebra.txt _under.txt aa-untracked.txt zz-tracked.txt " \
  "the list is in byte order, whatever locale the suite is run in"
list_in_order "$o"
assert_true $? "the list is sorted, tracked and untracked names together"
rm -f "$o" "$o.argv"; rm -rf "$o_repo"
