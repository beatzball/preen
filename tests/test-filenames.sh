#!/usr/bin/env bash
# Awkward filenames: the list and the preview must spell a path the same way.
#
# git escapes some names on output, and a name that comes back escaped is
# listed but cannot then be opened — the list looks right and the preview is
# blank. core.quotePath=false in the gitw helper covers the accented case; git
# escapes quotes, backslashes and control characters regardless of it, and
# those are tracked in issue #3.
set -u
. "$(dirname "$0")/lib.sh"

d="$(new_repo)"; s=""
trap 'rm -rf "$d" "$s"' EXIT
s="$(preen_state diff sbs "" "")"

# Everything here is created as both a tracked-and-modified file and an
# untracked one, because the two halves of the list are built by different git
# commands and only one of them used to carry the flag.
add_tracked() { printf 'one\n' > "$d/$1"; }
add_untracked() { printf 'one\n' > "$d/$1"; }

add_tracked   'café.txt'
add_tracked   'with space.txt'
add_tracked   'plain.txt'
tgit -C "$d" add -A; tgit -C "$d" commit -qm "names"
for f in 'café.txt' 'with space.txt' 'plain.txt'; do printf 'two\n' >> "$d/$f"; done
add_untracked 'untracked-café.txt'
add_untracked 'untracked space.txt'

list="$(preen_list "$d" diff)"

# ---- names that must work ----------------------------------------------------
while IFS= read -r name; do
  printf '%s\n' "$list" | grep -qxF "$name"
  assert_true $? "listed unescaped: $name"

  out="$(cd "$d" && preview "$s" "$name")"
  assert_nonempty "$out" "previews: $name"
done <<'NAMES'
plain.txt
café.txt
with space.txt
untracked-café.txt
untracked space.txt
NAMES

# A leading dash is safe only because every call site puts `--` before the
# path. Without that git reads the name as an option and the preview dies.
printf 'dash\n' > "$d/-leading.txt"
list="$(preen_list "$d" diff)"
printf '%s\n' "$list" | grep -qxF -- '-leading.txt'
assert_true $? "listed: -leading.txt"
# The preview callback takes the name as its own argument, so a leading dash
# is never parsed as an option by the shell here either.
out="$(PREEN_STATE="$s" FZF_PREVIEW_COLUMNS=100 bash -c 'cd "$1" && "$2" --preview "$3"' _ "$d" "$PREEN" '-leading.txt' 2>/dev/null | strip_ansi)"
assert_nonempty "$out" "previews: -leading.txt"

# ---- the known limits, from issue #3 ----------------------------------------
# git escapes these whatever core.quotePath says, so they are still broken.
# Written as assertions of the CURRENT behaviour rather than skipped: when #3
# lands these flip to failures and say so, which is the point.
printf 'q\n' > "$d/has\"quote.txt"
list="$(preen_list "$d" diff)"
if printf '%s\n' "$list" | grep -qxF 'has"quote.txt'; then
  assert_eq "unescaped" "escaped" "KNOWN LIMIT #3: a quote in a name is still escaped — this now WORKS, update the test"
else
  assert_eq "escaped" "escaped" "known limit #3: a quote in a name comes back escaped"
fi
rm -f "$d/has\"quote.txt"

# ---- ordinary names are untouched by any of this ----------------------------
# The flag must not change behaviour for the names everyone actually uses.
plain="$(preen_list "$d" diff | grep -c '^plain.txt$')"
assert_eq "$plain" "1" "an ordinary name is listed exactly once, unchanged"
