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
