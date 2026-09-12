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

d="$(new_repo)"; s=""; wtroot=""; wtroot2=""; mdd=""; shim=""
prd=""; spr=""; edbin=""; edlog=""; raw2=""; raw2t=""; rend=""; sren=""
raw="$(mktemp "${TMPDIR:-/tmp}/preen-raw.XXXXXX")"
# Every temp path this file makes, named rather than globbed: `"$raw".*` with
# an empty $raw is `.*`, which reaches the dotfiles of whatever directory the
# suite was started from.
cleanup() {
  rm -rf "$d" "$s" "$wtroot" "$wtroot2" "$mdd" "$shim" "$prd" "$spr" "$edbin" "$rend" "$sren" \
         "${_preen_dep_shim:-}"
  rm -f "$edlog" ${raw:+"$raw" "$raw.argv"} \
        ${raw2:+"$raw2" "$raw2.argv" "$raw2.n" "$raw2.level1"} \
        ${raw2t:+"$raw2t" "$raw2t.argv" "$raw2t.n" "$raw2t.level1"}
}
trap cleanup EXIT
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

# 4. The picker has to be told how to read that list. A perfect NUL-framed
#    list still arrives as two entries if fzf is left splitting on newline,
#    which is the same bug one layer further on. The shim records the flags
#    preen passed, and real fzf shows what the flag is worth.
printf '%s\n' "$(list_flags "$raw")" | grep -qx -- '--read0'
assert_true $? "fzf is told to read the list on NUL (--read0)"

# fzf --filter needs no terminal, so the real binary can be asked directly.
# Same bytes, once with the flag and once without.
n_with="$(fzf --read0 --filter='' --print0 < "$raw" | list_count /dev/stdin)"
n_without="$(fzf --filter='' --print0 < "$raw" | list_count /dev/stdin)"
assert_eq "$n_with" "$(list_count "$raw")" "real fzf keeps one entry per file with --read0"
[ "$n_without" != "$n_with" ]
assert_true $? "real fzf splits the list differently without it — the flag is what does the work"

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
# A space in the worktree's own path, because that is what tells a quoted
# expansion from an unquoted one when ctrl-e spends it further down.
mkdir -p "$wtroot/odd dir"
wt="$wtroot/odd dir/w"
git -C "$d" worktree add -q -b odd "$wt" 2>/dev/null

# wt_files has two halves, built by two different git commands, and a fixture
# that only writes new files exercises one of them. So: three names of their
# own for the untracked half...
printf 'MARKER-quote\n'   > "$wt/wt\"quote.txt"
printf 'MARKER-slash\n'   > "$wt/wt\\slash.txt"
printf 'MARKER-newline\n' > "$wt/"$'wt\nnewline.txt'
# ...and a modification to a name the repo already tracks for the other half.
# It has to be an odd name too: `diff --name-only` escapes it exactly the way
# `ls-files --others` does, so a plain name here would prove nothing.
printf 'MARKER-tracked\n' >> "$wt/"$'two\nlines.txt'

swt="$(preen_state wt sbs "" "")"
out="$(preview "$swt" "$wt")"
assert_contains "$out" "MARKER-quote"   "worktree preview opens a name with a quote"
assert_contains "$out" "MARKER-slash"   "worktree preview opens a name with a backslash"
assert_contains "$out" "MARKER-newline" "worktree preview opens a name with a newline"
assert_contains "$out" "MARKER-tracked" "worktree preview shows a modified tracked file as well as the untracked ones"

# ---- worktrees level two -----------------------------------------------------
# The file list inside a worktree, which nothing else in the suite reaches: the
# ordinary shim stops at level one. Same contract as diff mode — one entry per
# file, spelled as itself.
raw2="$(mktemp "${TMPDIR:-/tmp}/preen-raw2.XXXXXX")"
preen_list_raw2 "$raw2" "$d" worktrees
for n in 'wt"quote.txt' 'wt\slash.txt' $'wt\nnewline.txt' $'two\nlines.txt'; do
  list_has "$raw2" "$n"
  assert_true $? "worktree level two lists as one entry: $(q "$n")"
done
assert_eq "$(list_count "$raw2")" "4" "worktree level two holds one entry per file"

# ctrl-e opens the file in the worktree, so the worktree's own path has to
# reach the editor — and it must not reach it as command text. This worktree is
# called `wt` and lives under a path with no metacharacters, so the check is on
# the shape: fzf quotes {} itself, and the path is spent as a variable the
# executing shell expands, never pasted in.
bind="$(list_bind "$raw2" 'ctrl-e')"
assert_contains "$bind" 'PREEN_WT_DIR' "ctrl-e takes the worktree path from the environment"
assert_not_contains "$bind" "$wt" "ctrl-e does not paste the worktree path into the command"

# Both of those grade the shape of a string. The quoting inside it is what does
# the work, so run the thing: strip fzf's own `execute(...)` wrapper, put a
# shell-quoted filename where fzf puts one, and let a shell have it. A path
# with a space in it is what an unquoted $PREEN_WT_DIR breaks on.
cmd="${bind#execute(}"; cmd="${cmd%)}"
edlog="$(mktemp "${TMPDIR:-/tmp}/preen-ed.XXXXXX")"
edbin="$(mktemp -d "${TMPDIR:-/tmp}/preen-edbin.XXXXXX")"
cat > "$edbin/ed" <<EOF
#!/bin/sh
printf '%s\n' "\$#" > "$edlog"
printf '%s\n' "\$1" >> "$edlog"
[ -e "\$1" ] && printf 'exists\n' >> "$edlog" || printf 'missing\n' >> "$edlog"
EOF
chmod +x "$edbin/ed"
( export PREEN_WT_DIR="$wt" EDITOR="$edbin/ed"
  sh -c "$(printf '%s' "$cmd" | sed "s|{}|'wt\"quote.txt'|")" ) >/dev/null 2>&1

assert_eq "$(sed -n 1p "$edlog")" "1"      "ctrl-e hands the editor exactly one argument"
assert_eq "$(sed -n 3p "$edlog")" "exists" "ctrl-e opens a file that is really there"



count="$(preen_list "$d" worktrees | head -n 1 | awk '{print $1}')"
shown="$(printf '%s\n' "$out" | grep -c 'MARKER-')"
assert_eq "$count" "4" "the worktree counts all four odd names, tracked and untracked"
assert_eq "$shown" "$count" "count and level-one preview agree"
rm -rf "$swt"
git -C "$d" worktree remove --force "$wt" 2>/dev/null

# ---- a tab in the worktree's OWN directory name -----------------------------
# Every list above is about a file inside a worktree. This one is about the
# worktree record itself, which is two fields — a label for the eye, then the
# absolute path the callbacks are handed — and the label ENDS with that same
# path. So a tab in the directory name put a SECOND tab in a tab-joined record,
# and fzf's `{2}` handed the callbacks the tail of the label instead of a path.
#
# Nothing crashed. The pane said "2 files" and level two said the branch had
# changed nothing, which is the whole reason this needs an assertion: the count
# and the pane contradicted each other and neither looked like an error.
wtroot2="$(mktemp -d "${TMPDIR:-/tmp}/preen-wtroot2.XXXXXX")"
# Resolved, because this is the one worktree test that compares preen's idea of
# the path with the fixture's. git prints the real path, and on macOS $TMPDIR is
# /var/folders/... — a symlink into /private/var, so the two spellings differ.
tabwt="$(cd "$wtroot2" && pwd -P)/has"$'\t'"tab"
git -C "$d" worktree add -q -b tabbed "$tabwt" 2>/dev/null
printf 'MARKER-tab-one\n' > "$tabwt/tab-new1.txt"
printf 'MARKER-tab-two\n' > "$tabwt/tab-new2.txt"

preen_list_raw "$raw" "$d" worktrees

# The separator is read out of the flags preen actually passed, so the split
# below cannot pass by agreeing with a guess hard-coded in this file.
US="$(printf '\037')"
sep="$(list_flags "$raw" | sed -n 's/^--delimiter=//p')"
assert_eq "$sep" "$US" "the worktree record is joined on US (0x1f), which a path cannot hold"

# The field the callbacks are spent: it has to be the worktree, tab and all.
rec=""; IFS= read -r -d '' rec < "$raw" || true
recdir="${rec#*"$US"}"
assert_eq "$recdir" "$tabwt" "the record's path field is the worktree's own path"
[ -d "$recdir" ]
assert_true $? "and that path is a directory that exists"

# The symptom itself, end to end: level two inside that worktree. With the
# record split in the wrong place `dir` is not a directory, wt_files comes back
# empty, and preen paints the "changed nothing" placeholder over two real files.
raw2t="$(mktemp "${TMPDIR:-/tmp}/preen-raw2t.XXXXXX")"
preen_list_raw2 "$raw2t" "$d" worktrees
assert_eq "$(list_count "$raw2t")" "2" \
  "level two inside a tab-named worktree lists both its files"
for n in 'tab-new1.txt' 'tab-new2.txt'; do
  list_has "$raw2t" "$n"
  assert_true $? "tab-named worktree, level two lists: $(q "$n")"
done
assert_not_contains "$(tr '\0' '\n' < "$raw2t")" "changed nothing" \
  "level two is the file list, not the empty-worktree placeholder"

git -C "$d" worktree remove --force "$tabwt" 2>/dev/null

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

# ---- md mode on a directory whose name starts with a dash -------------------
# `find -weird ...` reads the name as a bundle of options — `find: illegal
# option -- w` — and md mode then said "nothing to show (md mode)". The status
# and the message were both right, which is what made it read as noise: the
# files are there and none of them was listed.
mkdir -p "$mdd/-weird"
printf '# one\n' > "$mdd/-weird/a.md"
printf '# two\n' > "$mdd/-weird/b.md"

preen_list_raw "$raw" "$mdd" md -weird
assert_eq "$(list_count "$raw")" "2" "md mode finds the files under a dash-leading directory"

# The `./` stays on these names. It is what keeps the renderer and $EDITOR from
# reading `-weird/a.md` as options in their turn, so trimming it here would
# trade find's complaint for a blank preview.
for n in './-weird/a.md' './-weird/b.md'; do
  list_has "$raw" "$n"
  assert_true $? "md mode keeps the ./ that makes the name openable: $(q "$n")"
done

# And the names are not just well-shaped, they resolve. The `seen` count is the
# guard: with nothing listed, the loop would pass by never running.
missing=""; seen=0
while IFS= read -r -d '' entry || [ -n "$entry" ]; do
  seen=$((seen + 1))
  [ -f "$mdd/$entry" ] || missing="$missing $(q "$entry")"
  entry=""
done < "$raw"
assert_eq "$missing" "" "every name md mode listed under -weird is a file that is really there"
assert_eq "$seen" "2" "that loop saw both of them"

# The complaint itself, which is the part a person sees.
nofzfmd="$(mktemp -d "${TMPDIR:-/tmp}/preen-nofzfmd.XXXXXX")"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$nofzfmd/fzf"
chmod +x "$nofzfmd/fzf"
# Empty, not "no 'illegal option'": that wording is BSD find's, GNU find says
# "unknown predicate", and the run has nothing to say on stderr either way.
mderr="$(cd "$mdd" && PATH="$nofzfmd:$PATH" "$PREEN" md -weird 2>&1 >/dev/null </dev/null || true)"
assert_eq "$mderr" "" "md mode on a dash-leading directory is silent: no complaint, no 'nothing to show'"
rm -rf "$nofzfmd"

# ---- pr mode ----------------------------------------------------------------
# Two separate things to hold shut here.
#
# The list: gh has no -z, so it is newline-delimited whatever preen does. A name
# with a space or a quote still has to survive being carried into it — it would
# not if the list were rebuilt by word splitting. A name containing a newline
# cannot be represented here at all, because gh separates its output with one.
#
# The preview: git C-quotes the WHOLE path in a `diff --git` header when the
# name holds a quote, a backslash, a control character or a byte above 0x7f,
# whatever core.quotePath says — so an accented name arrives from the API as
# `"b/caf\303\251.md"`. A tail match on " b/NAME" never matches that, and the
# preview came back blank: issue #3's symptom, in the one mode where the file
# being empty and the file being unfindable look identical.
# The diff the stub serves is generated by real git, NOT written out here: the
# quoting in a `diff --git` header is git's own, and inventing it would grade
# this file's idea of the format rather than the format. No core.quotePath=false
# either — this is the spelling the GitHub API returns, where an accented name
# is octal-escaped as well.
prd="$(mktemp -d "${TMPDIR:-/tmp}/preen-prsrc.XXXXXX")"
git init -q -b main "$prd"
pr_names=( 'plain.txt' 'with space.txt' 'has"quote.txt' 'back\slash.txt'
           $'tab\there.txt' 'café.txt'
           # These two differ only by a wrapping pair of double quotes. A
           # name that is spelled like a quoted name, but is just a name,
           # must not match the block belonging to its own interior.
           '"quoted"' 'quoted'
           # And these two are the pair from #22. A space does not make git
           # quote a header, so `x.md` arrives as `diff --git a/x.md b/x.md`
           # and ` b/x.md` as `diff --git a/ b/x.md b/ b/x.md` -- whose last
           # seven bytes ARE ` b/x.md`. The tail match took that for x.md's own
           # block and the preview showed the two files stitched together.
           # They go last, so the two markers below can be worked out.
           'x.md' ' b/x.md' )
mkdir -p "$prd/ b"
i=0
for n in "${pr_names[@]}"; do printf 'PR-%s-before\n' "$i" > "$prd/$n"; i=$((i + 1)); done
tgit -C "$prd" add -A; tgit -C "$prd" commit -qm pr
i=0
for n in "${pr_names[@]}"; do printf 'PR-%s-after\n' "$i" >> "$prd/$n"; i=$((i + 1)); done
git -C "$prd" diff HEAD > "$prd/pr.diff"

# Nobody here knows which spelling the real `gh pr diff --name-only` prints for
# a name git would quote — gh parses the patch itself and preen never sees the
# repository. So run it both ways: `raw`, and the C-quoted spelling git uses.
# The list may end up showing either, but every entry in it has to open.
pr_run() {
  # pr_run <raw|quoted> -> stubs gh, builds the list into $raw
  local how="$1"
  shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-gh.XXXXXX")"
  if [ "$how" = quoted ]; then
    ( cd "$prd" && git diff --name-only HEAD ) > "$shim/names"
  else
    printf '%s\n' "${pr_names[@]}" > "$shim/names"
  fi
  cat > "$shim/gh" <<GH
#!/bin/sh
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")     printf '7\tOdd names\n'; exit 0 ;;
  "pr diff")
    for a in "\$@"; do [ "\$a" = "--name-only" ] && { cat "$shim/names"; exit 0; }; done
    cat "$prd/pr.diff"
    exit 0 ;;
esac
exit 1
GH
  chmod +x "$shim/gh"
  PATH="$shim:$PATH" preen_list_raw "$raw" "$d" pr 7
}

spr="$(preen_state pr sbs "" "")"
cp "$prd/pr.diff" "$spr/pr.diff"

for how in raw quoted; do
  pr_run "$how"

  assert_eq "$(list_count "$raw")" "${#pr_names[@]}" \
    "pr/$how: one entry per file in the PR"

  # Every entry in the list opens, and opens on ITS OWN file. The content is
  # unique per file, because the rendered diff header carries git's escaped
  # spelling of the name rather than the name, so matching on the name would
  # grade the wrong thing.
  # Which order gh lists them in is gh's business, so this collects the marker
  # each preview carried and checks the SET: every file exactly once means no
  # entry opened a neighbour's block and none opened nothing.
  blank=""; seen=0; marks=""
  while IFS= read -r -d '' entry || [ -n "$entry" ]; do
    out="$(preview "$spr" "$entry")"
    [ -n "$out" ] || blank="$blank $(q "$entry")"
    marks="$marks$(printf '%s\n' "$out" | grep -o 'PR-[0-9]*-after' | sort -u)
"
    seen=$((seen + 1)); entry=""
  done < "$raw"

  want=""
  i=0; while [ "$i" -lt "${#pr_names[@]}" ]; do want="$want PR-$i-after"; i=$((i + 1)); done
  got="$(printf '%s' "$marks" | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//')"

  assert_eq "$seen"  "${#pr_names[@]}" "pr/$how: that loop saw every entry"
  assert_eq "$blank" ""                "pr/$how: every entry in the list previews"
  assert_eq "$got" "${want# }"         "pr/$how: each entry previewed its own file, exactly once"
  rm -rf "$shim"
done

# The list itself: with the raw spelling, each name has to survive being
# carried into it — it would not if the list were rebuilt by word splitting.
pr_run raw
for n in "${pr_names[@]}"; do
  list_has "$raw" "$n"
  assert_true $? "pr mode holds gh's name as one entry, unsplit: $(q "$n")"
done

# ---- the ` b/x.md` over-match, named --------------------------------------
# The set check above catches this too, but only as one name out of ten. Say
# what it is: each of the pair previews its own block and not the other's.
# The markers are positional, and these two were appended last.
mk_x="PR-$(( ${#pr_names[@]} - 2 ))-after"
mk_b="PR-$(( ${#pr_names[@]} - 1 ))-after"

out="$(preview "$spr" 'x.md')"
assert_contains     "$out" "$mk_x" "pr: x.md previews its own file"
assert_not_contains "$out" "$mk_b" "pr: and not the block of the file named ' b/x.md' as well"

out="$(preview "$spr" ' b/x.md')"
assert_contains     "$out" "$mk_b" "pr: a file named ' b/x.md' previews its own file"
assert_not_contains "$out" "$mk_x" "pr: and not x.md's block as well"

# ---- pr mode: a rename, which is the case the arithmetic must decline -------
# An unquoted header is `a/P b/P` for everything but a rename, and solving for
# P is what settles the over-match above. A rename's two paths differ, so the
# solved P is not a path at all — with names of unequal length it comes out as
# a tail of the real one — and the renamed file would preview blank. The fix
# has to hand that case back to the tail match, and these names are of unequal
# length on purpose: `a/a.md b/bbbbb.md` solves to `bbb.md`, which is nobody.
rend="$(mktemp -d "${TMPDIR:-/tmp}/preen-prren.XXXXXX")"
git init -q -b main "$rend"
# Long enough that git's similarity detection actually calls it a rename. With
# a one-line file it reports a delete and an add instead, and both of those
# carry an `a/P b/P` header — so the fixture would have named the case and
# never reached it.
{ echo 'RENAMED-BODY'; for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done; } > "$rend/a.md"
printf 'UNTOUCHED-BODY\n' > "$rend/keep.md"
tgit -C "$rend" add -A; tgit -C "$rend" commit -qm init
tgit -C "$rend" mv a.md bbbbb.md
printf 'RENAMED-AFTER\n' >> "$rend/bbbbb.md"
tgit -C "$rend" add -A

sren="$(preen_state pr sbs "" "")"
git -C "$rend" diff -M --cached HEAD > "$sren/pr.diff"
assert_contains "$(grep '^diff --git' "$sren/pr.diff")" 'a/a.md b/bbbbb.md' \
  "the fixture really is a rename, with two different paths in one header"

out="$(preview "$sren" 'bbbbb.md')"
assert_contains     "$out" "RENAMED-AFTER"  "pr: a renamed file previews its own block"
assert_not_contains "$out" "UNTOUCHED-BODY" "pr: and not the next file's along with it"


# ---- ordinary names are untouched by any of this ----------------------------
# None of the above may change behaviour for the names everyone actually uses.
plain="$(preen_list "$d" diff | grep -c '^plain.txt$')"
assert_eq "$plain" "1" "an ordinary name is listed exactly once, unchanged"
