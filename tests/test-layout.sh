#!/usr/bin/env bash
# The layout a run starts in (#8): PREEN_LAYOUT, then git config preen.layout,
# then side-by-side -- for the picker, its previews, ctrl-s, and piped input.
#
# Two places pick the layout: the picker writes it to $PREEN_STATE/mode, and
# piped input asks layout_mode(). Both are driven here through the real binary,
# so a source that only one of them reads turns this file red.
set -u
. "$(dirname "$0")/lib.sh"

# The developer's own settings must not leak in: a preen.layout in their
# ~/.gitconfig would decide every assertion below. GIT_CONFIG_GLOBAL stands in
# for both ~/.gitconfig and the XDG file; the system file is switched off.
unset PREEN_LAYOUT
mktmpd home preen-layout-home
mktmpf gcfg preen-layout-gcfg
HOME="$home"; XDG_CONFIG_HOME="$home/.config"
GIT_CONFIG_GLOBAL="$gcfg"; GIT_CONFIG_NOSYSTEM=1
export HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

# ---- the stand-ins -----------------------------------------------------------
# delta logs the --features it was asked for, which is the layout. fzf does
# what a person would: look at the first preview, press ctrl-s, look again.
# Both go through the same callbacks the real picker uses.
mktmpd shim preen-layout-shim
log="$shim/log"; err="$shim/err"
cat > "$shim/delta" <<'EOF'
#!/bin/sh
prev=""
for a in "$@"; do
  [ "$prev" = --features ] && printf 'delta=%s\n' "$a" >> "$PREEN_T_LOG"
  prev="$a"
done
cat > /dev/null
EOF
cat > "$shim/fzf" <<'EOF'
#!/bin/sh
cat > /dev/null
printf 'start=%s\n' "$(cat "$PREEN_STATE/mode")" >> "$PREEN_T_LOG"
"$PREEN_SELF" --preview f.txt > /dev/null 2>&1
"$PREEN_SELF" --toggle
printf 'toggled=%s\n' "$(cat "$PREEN_STATE/mode")" >> "$PREEN_T_LOG"
"$PREEN_SELF" --preview f.txt > /dev/null 2>&1
exit 0
EOF
chmod +x "$shim/delta" "$shim/fzf"
export PREEN_T_LOG="$log"

d="$(new_repo)" || exit 1
mktmpd out preen-layout-out          # no repository above it, see below
trap 'rm -rf "$d" "$out" "$shim" "$home" "$gcfg" "${_preen_dep_shim:-}"' EXIT
printf 'changed\n' >> "$d/f.txt"
git -C "$d" diff > "$shim/diff"
printf '# notes\n' > "$out/notes.md"   # md mode needs something to list

# Outside a repository means outside every repository: a $TMPDIR that happens
# to sit inside a checkout would otherwise answer with that checkout's config.
GIT_CEILING_DIRECTORIES="$(dirname "$out")"; export GIT_CEILING_DIRECTORIES

picker() {
  # picker <cwd> <mode> -> the log: start, the delta the first preview used, the
  # mode after ctrl-s, and the delta the second preview used. stderr goes to
  # $err and the exit status to $err.rc.
  : > "$log"
  ( cd "$1" && PATH="$shim:$PATH" "$PREEN" "$2" > /dev/null 2> "$err" )
  printf '%s' "$?" > "$err.rc"
  tr '\n' ' ' < "$log"
}

piped() {
  # piped <cwd> -> the delta layout a piped diff was rendered with
  : > "$log"
  ( cd "$1" && PATH="$shim:$PATH" "$PREEN" - < "$shim/diff" > /dev/null 2> "$err" )
  printf '%s' "$?" > "$err.rc"
  tr '\n' ' ' < "$log"
}

SBS='start=sbs delta=sbs toggled=inline delta=inline '
INL='start=inline delta=inline toggled=sbs delta=sbs '

# ---- nothing set --------------------------------------------------------------
assert_eq "$(picker "$d" diff)" "$SBS" "no setting starts side-by-side, ctrl-s flips to inline"

# ---- the repository's own config ------------------------------------------------
git -C "$d" config preen.layout inline
assert_eq "$(picker "$d" diff)" "$INL" "preen.layout inline starts the picker inline, ctrl-s flips back"
mkdir -p "$d/sub"
assert_eq "$(picker "$d/sub" diff)" "$INL" "and from a subdirectory"
assert_eq "$(piped "$d")" "delta=inline " "preen.layout inline renders piped input inline"

# ---- the environment variable wins ---------------------------------------------
assert_eq "$(PREEN_LAYOUT=sbs picker "$d" diff)" "$SBS" "PREEN_LAYOUT=sbs beats preen.layout inline"
assert_eq "$(PREEN_LAYOUT=sbs piped "$d")" "delta=sbs " "and on piped input"
git -C "$d" config preen.layout sbs
assert_eq "$(PREEN_LAYOUT=inline picker "$d" diff)" "$INL" "PREEN_LAYOUT=inline beats preen.layout sbs"
# An empty PREEN_LAYOUT is unset, as it always was: it does not hide the config.
git -C "$d" config preen.layout inline
assert_eq "$(PREEN_LAYOUT= picker "$d" diff)" "$INL" "an empty PREEN_LAYOUT falls through to preen.layout"

# ---- values that are not inline -------------------------------------------------
# Same rule as the environment variable has always had: only the exact word.
for v in INLINE Inline bogus "inline " ""; do
  git -C "$d" config preen.layout "$v"
  assert_eq "$(picker "$d" diff)" "$SBS" "preen.layout [$v] is side-by-side"
  assert_eq "$(cat "$err")" "" "preen.layout [$v] prints nothing"
done
git -C "$d" config --unset preen.layout

# ---- global, and its place below the repository ----------------------------------
git config --file "$gcfg" preen.layout inline
assert_eq "$(picker "$d" diff)" "$INL" "a global preen.layout inline is a default for every repository"
assert_eq "$(piped "$d")" "delta=inline " "and for piped input"
git -C "$d" config preen.layout sbs
assert_eq "$(picker "$d" diff)" "$SBS" "the repository's preen.layout beats the global one"
git -C "$d" config --unset preen.layout

# ---- outside any repository -----------------------------------------------------
# preen opens md mode here. Only the global file can answer, and git saying
# "not a git repository" must not reach the screen.
git -C "$out" rev-parse --git-dir > /dev/null 2>&1
assert_eq "$?" "128" "the outside fixture is really outside a repository"
got="$(picker "$out" md)"
assert_contains "$got" "start=inline" "outside a repository the global preen.layout still applies"
assert_eq "$(cat "$err")" "" "and prints nothing"
assert_eq "$(piped "$out")" "delta=inline " "piped input outside a repository reads the global one"
assert_eq "$(cat "$err")" "" "and prints nothing"

: > "$gcfg"
got="$(picker "$out" md)"
assert_contains "$got" "start=sbs" "outside a repository with no setting is side-by-side"
assert_eq "$(cat "$err")" "" "and prints nothing"
assert_eq "$(cat "$err.rc")" "0" "and exits 0"
assert_eq "$(piped "$out")" "delta=sbs " "piped input there is side-by-side"
assert_eq "$(cat "$err")" "" "and prints nothing"
assert_eq "$(cat "$err.rc")" "0" "and exits 0"

# ---- a config file git cannot read -----------------------------------------------
# git prints "fatal: bad config line" for it. That is not preen's to show over
# the picker; preen starts side-by-side instead.
printf '[preen\nlayout = inline\n' > "$gcfg"
got="$(picker "$out" md)"
assert_contains "$got" "start=sbs" "an unreadable config starts side-by-side"
assert_eq "$(cat "$err")" "" "and git's complaint is not printed"
assert_eq "$(piped "$out")" "delta=sbs " "piped input with an unreadable config is side-by-side"
assert_eq "$(cat "$err")" "" "and git's complaint is not printed"
: > "$gcfg"
