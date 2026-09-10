#!/usr/bin/env bash
# Awkward filenames: the list and the preview must spell a path the same way.
#
# git escapes some names on output, and a name that comes back escaped is
# listed but cannot then be opened — the list looks right and the preview is
# blank. core.quotePath=false in the gitw helper covers the accented case. A
# double quote, a backslash and a newline are escaped whatever that setting
# says, which is issue #3: the fix is -z on every command that prints a path,
# `read -d ""` on the consuming side, and --read0 into fzf.
#
# A newline is the hard one. It is escaped on output AND it is the separator
# the list used to be joined with, so it broke the list twice over: one file
# arriving as two entries, neither of them a real name.
set -u
. "$(dirname "$0")/lib.sh"

d="$(new_repo)"; s=""; wtroot=""; mdd=""; shim=""
raw="$(mktemp "${TMPDIR:-/tmp}/preen-raw.XXXXXX")"
trap 'rm -rf "$d" "$s" "$wtroot" "$mdd" "$shim"; rm -f "$raw"' EXIT
s="$(preen_state diff sbs "" "")"

# printf %q, so a name containing a newline still prints as one readable line
# in a PASS or FAIL label.
q() { printf '%q' "$1"; }

# Every name is created twice, once tracked-and-modified and once untracked,
# because the two halves of the list are built by different git commands and a
# flag has been missed from one of them before.
tracked=(
  'plain.txt'
  'café.txt'
  'with space.txt'
  'has"quote.txt'
  'back\slash.txt'
  $'two\nlines.txt'
)
untracked=(
  'untracked-café.txt'
  'untracked space.txt'
  'untracked"quote.txt'
  'untracked\slash.txt'
  $'untracked\nnewline.txt'
)

for n in "${tracked[@]}"; do printf 'one\n' > "$d/$n"; done
tgit -C "$d" add -A; tgit -C "$d" commit -qm "names"
for n in "${tracked[@]}"; do printf 'two\n' >> "$d/$n"; done
for n in "${untracked[@]}"; do printf 'one\n' > "$d/$n"; done

# ---- diff mode --------------------------------------------------------------
preen_list_raw "$raw" "$d" diff

# 1. The escaping, on its own. This asks nothing about how the entries are
#    separated, only whether the name survived git: `has"quote.txt` came back
#    as `has\"quote.txt` and a name that is spelled that way cannot be opened.
for n in 'has"quote.txt' 'back\slash.txt' $'two\nlines.txt' \
         'untracked"quote.txt' 'untracked\slash.txt' $'untracked\nnewline.txt'; do
  list_holds_name "$raw" "$n"
  assert_true $? "reaches the list unescaped: $(q "$n")"
done

# 2. The framing. One entry per file: a newline in a name is also the byte the
#    list used to be joined with, so that one file arrived as two entries and
#    the total came out too high, before anything tried to open them.
assert_eq "$(list_count "$raw")" "$(( ${#tracked[@]} + ${#untracked[@]} ))" \
  "one entry per file — a newline in a name did not split it in two"

for n in "${tracked[@]}" "${untracked[@]}"; do
  list_has "$raw" "$n"
  assert_true $? "listed as one entry: $(q "$n")"
done

# 3. What the two of them are for: every entry the list carries can be opened.
#    This is the symptom in #3 — the list looks right and the preview is blank
#    — and it grades the entry as the list spells it, not as the test does.
#    The `|| [ -n "$entry" ]` is not decoration: a list with no NUL in it at
#    all leaves read with a partial record and a non-zero status, and without
#    it the loop would never run and pass by doing nothing.
blank=""; seen=0
while IFS= read -r -d '' entry || [ -n "$entry" ]; do
  seen=$((seen + 1))
  out="$(cd "$d" && preview "$s" "$entry")"
  [ -n "$out" ] || blank="$blank $(q "$entry")"
  entry=""
done < "$raw"
assert_eq "$blank" "" "every entry in the list previews"
assert_eq "$seen" "$(list_count "$raw")" "that loop saw every entry"

# ---- a leading dash ---------------------------------------------------------
# Safe only because every call site puts `--` before the path. Without that git
# reads the name as an option and the preview dies.
printf 'dash\n' > "$d/-leading.txt"
preen_list_raw "$raw" "$d" diff
list_has "$raw" '-leading.txt'
assert_true $? "listed: -leading.txt"
# The preview callback takes the name as its own argument, so a leading dash
# is never parsed as an option by the shell here either.
out="$(PREEN_STATE="$s" FZF_PREVIEW_COLUMNS=100 bash -c 'cd "$1" && "$2" --preview "$3"' _ "$d" "$PREEN" '-leading.txt' 2>/dev/null | strip_ansi)"
assert_nonempty "$out" "previews: -leading.txt"

# ---- worktrees mode: the count and the preview still have to agree ----------
# The symptom reported in #3: eight files counted, six of them previewable,
# because the count came from a list of escaped names and the preview tried to
# open them. Each file carries its own marker, so "shown" is countable.
wtroot="$(mktemp -d "${TMPDIR:-/tmp}/preen-wtroot.XXXXXX")"
wt="$wtroot/w"
git -C "$d" worktree add -q -b odd "$wt" 2>/dev/null

# Names of their own, not the ones committed above: written over a tracked
# file these would be modifications, and the untracked half of wt_files --
# the half #3 is about -- would never be reached.
printf 'MARKER-quote\n'   > "$wt/wt\"quote.txt"
printf 'MARKER-slash\n'   > "$wt/wt\\slash.txt"
printf 'MARKER-newline\n' > "$wt/"$'wt\nnewline.txt'

swt="$(preen_state wt sbs "" "")"
out="$(preview "$swt" "$wt")"
assert_contains "$out" "MARKER-quote"   "worktree preview opens a name with a quote"
assert_contains "$out" "MARKER-slash"   "worktree preview opens a name with a backslash"
assert_contains "$out" "MARKER-newline" "worktree preview opens a name with a newline"

count="$(preen_list "$d" worktrees | head -n 1 | awk '{print $1}')"
shown="$(printf '%s\n' "$out" | grep -c 'MARKER-')"
assert_eq "$count" "3" "the worktree counts all three odd names"
assert_eq "$shown" "$count" "count and level-one preview agree"
rm -rf "$swt"
git -C "$d" worktree remove --force "$wt" 2>/dev/null

# ---- md mode: the list comes from find, and has the same two problems -------
mdd="$(mktemp -d "${TMPDIR:-/tmp}/preen-md.XXXXXX")"
md_names=( 'plain.md' 'has"quote.md' 'back\slash.md' $'two\nlines.md' )
for n in "${md_names[@]}"; do printf '# heading\n' > "$mdd/$n"; done

preen_list_raw "$raw" "$mdd" md
# find prints a name unescaped, so md mode never had the escaping half of the
# bug — only the framing one, which the count is the assertion for.
assert_eq "$(list_count "$raw")" "${#md_names[@]}" \
  "md mode holds one entry per file, newline in a name and all"
for n in "${md_names[@]}"; do
  list_has "$raw" "$n"
  assert_true $? "md mode lists as one entry: $(q "$n")"
done

# ---- pr mode: gh has no -z, so the list is whatever gh printed --------------
# A name with a space or a quote has to survive being carried into the list —
# it would not if the list were rebuilt by word splitting. A name containing a
# newline cannot be represented here at all: gh separates its output with one.
shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-gh.XXXXXX")"
cat > "$shim/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view")     printf '7\tOdd names\n'; exit 0 ;;
  "pr diff")
    for a in "$@"; do [ "$a" = "--name-only" ] && {
      printf 'plain.txt\nwith space.txt\nhas"quote.txt\nback\\slash.txt\n'; exit 0; }
    done
    printf 'diff --git a/plain.txt b/plain.txt\n@@ -1 +1 @@\n-a\n+b\n'
    exit 0 ;;
esac
exit 1
GH
chmod +x "$shim/gh"

PATH="$shim:$PATH" preen_list_raw "$raw" "$d" pr 7
for n in 'plain.txt' 'with space.txt' 'has"quote.txt' 'back\slash.txt'; do
  list_has "$raw" "$n"
  assert_true $? "pr mode carries gh's name through whole: $(q "$n")"
done

# ---- ordinary names are untouched by any of this ----------------------------
# None of the above may change behaviour for the names everyone actually uses.
plain="$(preen_list "$d" diff | grep -c '^plain.txt$')"
assert_eq "$plain" "1" "an ordinary name is listed exactly once, unchanged"
