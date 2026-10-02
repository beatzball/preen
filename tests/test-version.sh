#!/usr/bin/env bash
# `preen --version`, and the two things it must survive: being reached through
# the symlink install.sh puts on PATH, and a checkout whose VERSION is not
# there. A version query is what someone runs on a broken install, so it is the
# one command that must never be the thing that fails.
set -u
. "$(dirname "$0")/lib.sh"

# What the file says, rather than a number written in here: this file must not
# have to be edited at every release, and "preen prints what VERSION holds" is
# the behavior anyway. The gate's own test is what holds VERSION to N.N.N.
want=""
[ -f "$PREEN_ROOT/VERSION" ] && IFS= read -r want < "$PREEN_ROOT/VERSION"

box=""
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set.
trap 'rm -rf ${box:+"$box"} "${_preen_dep_shim:-}"' EXIT
mktmpd box preen-version

# ---- the three spellings ----------------------------------------------------
if [ -n "$want" ]; then
  for flag in --version -V version; do
    out="$("$PREEN" "$flag" 2>&1)"; rc=$?
    assert_eq "$out" "preen $want" "preen $flag prints the version in VERSION"
    assert_eq "$rc" "0" "...and exits 0"
  done
else
  printf '  NOTE: no VERSION in this checkout, so there is no number to print\n'
fi

# ---- the help text ----------------------------------------------------------
help="$("$PREEN" --help 2>&1)"
assert_contains "$help" "--version" "--help lists the version flag"

# ---- a checkout with no VERSION ---------------------------------------------
# A copy, so the real file is never touched. bin/ and VERSION only: preen reads
# nothing else of the checkout, and copying .git would hand the copy this
# worktree's real repository.
copy="$box/copy"
mkdir -p "$copy/bin"
cp "$PREEN_ROOT/bin/preen" "$copy/bin/preen"
[ -f "$PREEN_ROOT/VERSION" ] && cp "$PREEN_ROOT/VERSION" "$copy/VERSION"

if [ -n "$want" ]; then
  out="$("$copy/bin/preen" --version 2>&1)"
  assert_eq "$out" "preen $want" "the copy is a faithful stand-in before VERSION is removed"
fi

rm -f "$copy/VERSION"
out="$("$copy/bin/preen" --version 2>&1)"; rc=$?
assert_eq "$out" "preen unknown" "a checkout with no VERSION reports unknown"
assert_eq "$rc" "0" "...and still exits 0"

# Unreadable, not just missing — a stray chmod is the other way this happens.
# Skipped as root, where mode 000 is still readable and the assertion would be
# about the user rather than about preen.
if [ -f "$PREEN_ROOT/VERSION" ] && [ "$(id -u)" != 0 ]; then
  cp "$PREEN_ROOT/VERSION" "$copy/VERSION"
  chmod 000 "$copy/VERSION"
  out="$("$copy/bin/preen" --version 2>&1)"; rc=$?
  assert_eq "$out" "preen unknown" "an unreadable VERSION reports unknown"
  assert_eq "$rc" "0" "...and still exits 0"
  chmod 644 "$copy/VERSION"
else
  printf '  NOTE: running as root, or no VERSION here, so the unreadable case is skipped\n'
fi

# ---- a VERSION with no final newline ----------------------------------------
# git does not insist on one, so this file shape reaches a real checkout. `read`
# returns non-zero at end of file with no terminator, having set the variable
# anyway, so a gate on read's STATUS reports unknown while holding the answer.
printf '%s' '9.9.9' > "$copy/VERSION"
out="$("$copy/bin/preen" --version 2>&1)"; rc=$?
assert_eq "$out" "preen 9.9.9" "a VERSION with no final newline is still reported"
assert_eq "$rc" "0" "...and exits 0"

# One line, not the file: `read` is what makes this the first line only, and a
# $(cat) with its errors silenced is otherwise indistinguishable from it. The
# release gate refuses a two-line VERSION; preen reports the number and says
# nothing about the rest.
printf '%s\n' '8.8.8' 'a stray second line' > "$copy/VERSION"
out="$("$copy/bin/preen" --version 2>&1)"
assert_eq "$out" "preen 8.8.8" "a VERSION with a stray second line reports the first line alone"

# ---- reached through a symlink, the way install.sh leaves it ----------------
# install.sh links $REPO/bin/preen into ~/.local/bin, so for everyone who
# installed preen this is the ONLY path that runs. Without the symlink walk,
# preen looks for VERSION next to the link and reports unknown for all of them.
if [ -n "$want" ]; then
  cp "$PREEN_ROOT/VERSION" "$copy/VERSION"
  mkdir -p "$box/bin"
  ln -sf "$copy/bin/preen" "$box/bin/preen"
  out="$("$box/bin/preen" --version 2>&1)"; rc=$?
  assert_eq "$out" "preen $want" "run through a symlink, preen still finds its VERSION"
  assert_eq "$rc" "0" "...and exits 0"

  # A relative link, resolved against the directory of the link itself.
  ( cd "$box/bin" && ln -sf ../copy/bin/preen relative-preen )
  out="$("$box/bin/relative-preen" --version 2>&1)"
  assert_eq "$out" "preen $want" "a relative symlink resolves against its own directory"

  # A link to a link, which is what a second install into another prefix makes.
  ln -sf "$box/bin/preen" "$box/bin/preen-again"
  out="$("$box/bin/preen-again" --version 2>&1)"
  assert_eq "$out" "preen $want" "a symlink to a symlink is followed to the end"
fi

# ---- a checkout whose path holds a space -------------------------------------
# Resolving the symlink is what makes this matter. preen hands fzf its own path
# in --preview and in three execute() binds, and fzf gives each of those to
# `$SHELL -c`. While SELF was the link in ~/.local/bin that path had no space in
# it; now it is the checkout, so a checkout under `~/my code` would split into
# two words and every callback would die with 127 -- a picker that draws a list
# and previews nothing.
#
# So this drives the real callback: preen builds it, a stand-in fzf reads the one
# the real picker would be given, and runs it the way fzf does -- through $SHELL,
# with the environment preen exported. Only fzf's own {} substitution is
# reconstructed here.
#
# diff mode rather than md mode, because the preview then renders through delta,
# which this suite requires, rather than through glow, which CI does not install.
spaced="$box/my code/preen"
mkdir -p "$spaced/bin" "$box/prefix"
cp "$PREEN_ROOT/bin/preen" "$spaced/bin/preen"
[ -f "$PREEN_ROOT/VERSION" ] && cp "$PREEN_ROOT/VERSION" "$spaced/VERSION"
ln -sf "$spaced/bin/preen" "$box/prefix/preen"

if [ -n "$want" ]; then
  out="$("$box/prefix/preen" --version 2>&1)"
  assert_eq "$out" "preen $want" "a checkout path with a space still reports its version"
fi

# The picker needs no VERSION, so this part runs on a checkout that has none —
# which is also what lets the harness sweep reach the two temporary paths below.
d="$(new_repo)" || exit 1
printf 'a line this test can look for\n' >> "$d/f.txt"

fzfshim=""
mktmpd fzfshim preen-cbshim
cat > "$fzfshim/fzf" <<'SHIM'
#!/usr/bin/env bash
# Stand in for fzf: record every argument preen passed, then run the --preview
# command the way fzf runs it, so a path that needs quoting fails here as it
# would there.
out="$PREEN_SHIM_OUT"
printf '%s\n' "$@" > "$out.argv"
preview=""
take=0
for a in "$@"; do
[ "$take" = 1 ] && { preview="$a"; take=0; }
[ "$a" = --preview ] && take=1
done
tr '\0' '\n' | head -n 1 > "$out.first"
name="$(cat "$out.first")"
# fzf single-quotes the selection itself; that is the one part of fzf rebuilt
# here. q holds one single quote, which is awkward to write inline.
q="'"
cmd="${preview//\{\}/$q$name$q}"
printf '%s\n' "$cmd" > "$out.cmd"
# TWO shells, because they do not agree about an unquoted variable. zsh does not
# split one into words, and zsh is the login shell on macOS -- so a callback that
# lost its inner quotes passes under zsh and dies under bash and sh. /bin/sh is
# the strict one and is what this grades; $SHELL is run as well, because that is
# the shell fzf will really use.
/bin/sh -c "$cmd" > "$out.preview" 2>&1
printf '%s\n' "$?" > "$out.rc"
${SHELL:-/bin/sh} -c "$cmd" > "$out.preview.shell" 2>&1
printf '%s\n' "$?" > "$out.rc.shell"
exit 0
SHIM
chmod +x "$fzfshim/fzf"

cb="$box/callback"
( cd "$d" && PATH="$fzfshim:$PATH" PREEN_SHIM_OUT="$cb" \
    "$box/prefix/preen" diff >/dev/null 2>&1 )

assert_eq "$(cat "$cb.rc" 2>/dev/null)" "0" \
  "under /bin/sh, the preview callback runs from a checkout path holding a space"
# Not just the exit status: a callback whose argument is mis-quoted also exits
# 0, having rendered nothing. This is the diff preen was asked for.
assert_contains "$(cat "$cb.preview" 2>/dev/null)" "a line this test can look for" \
  "...and renders the diff it was asked for"
assert_eq "$(cat "$cb.rc.shell" 2>/dev/null)" "0" \
  "and under this machine's own \$SHELL as well"

# Every argument, not only the --preview one. preen builds four callbacks that
# name its own path, and this file used to drive one of them: ctrl-s, and the
# enter bind, could each go back to a pasted path with the suite still green.
assert_not_contains "$(cat "$cb.argv" 2>/dev/null)" "my code" \
  "no flag preen gives fzf carries its own path as text"
rm -rf "$fzfshim" "$d"

# ---- the fourth callback: enter inside worktrees mode -----------------------
# bin/preen sets ENTER a second time for a worktree's file list, and nothing
# above reaches it: the diff-mode run never gets to level two. preen_list_raw2
# is the seam that does -- it accepts the first record, which drives preen into
# the second list -- and list_flags is what can see a flag at all.
#
# PREEN is overridden for the call so the seam drives the spaced copy rather
# than this checkout's own bin/preen.
wtbox=""; wtraw=""
mktmpd wtbox preen-wtbox
wtd="$(new_repo)" || exit 1
wt="$wtbox/feat"
git -C "$wtd" worktree add -q -b feat "$wt" 2>/dev/null
printf 'a change on the branch\n' >> "$wt/f.txt"
mktmpf wtraw preen-wtlist
PREEN="$box/prefix/preen" preen_list_raw2 "$wtraw" "$wtd" worktrees
assert_nonempty "$(list_flags "$wtraw")" "the worktrees seam reached preen's second list"
assert_not_contains "$(list_flags "$wtraw")" "my code" \
  "...and no flag there carries preen's own path either"
git -C "$wtd" worktree remove --force "$wt" 2>/dev/null || true
rm -rf "$wtbox" "$wtd"
rm -f "$wtraw" "$wtraw.argv" "$wtraw.level1" "$wtraw.n"

# ---- bin reached through a directory symlink ---------------------------------
# `cd -P`, not `cd`: a logical `..` from a linked bin/ climbs the link's parent
# instead of the checkout, and VERSION is not there.
if [ -n "$want" ]; then
  linked="$box/dirlink"
  mkdir -p "$linked"
  ln -sfn "$spaced/bin" "$linked/bin"
  out="$("$linked/bin/preen" --version 2>&1)"
  assert_eq "$out" "preen $want" "bin/ reached through a directory symlink still finds VERSION"
fi
