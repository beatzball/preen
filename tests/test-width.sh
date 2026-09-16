#!/usr/bin/env bash
# The width a render is asked for, and where preen gets it.
#
# Every render outside fzf measured the terminal with `$(tput cols)`. Inside
# `$( )` tput's stdout is a pipe, not the terminal, so it fell back to the
# terminfo default of 80 in every pane at every size. Widening a pane changed
# nothing, and in a pane narrower than 80 the pager wrapped every line a second
# time, mid-sentence. The width is read from the terminal itself now.
#
# glow is shimmed, so every assertion is about the `-w N` preen hands it and
# never about how glow lays a page out. less is shimmed to cat for the same
# reason: the pty is here to be measured, not to hold a pager open.
set -u
. "$(dirname "$0")/lib.sh"

# A developer's shell may export COLUMNS, and one test below sets it on
# purpose. Nothing else here may inherit it, or a pane-width assertion could
# pass on the variable rather than on the terminal.
unset COLUMNS

mktmpd shim preen-width
doc="$shim/note.md"
# lib.sh sets its own EXIT trap for the glow version stub, and a second trap
# would replace it rather than add to it, so remove both here. $st is set
# later, by preen_state; naming it while unset is harmless.
trap 'rm -rf "$shim" "${_preen_dep_shim:-}" "${st:-}"' EXIT

printf '# Notes\n\nA paragraph.\n' > "$doc"

# Prints the width it was given in brackets, so `WIDTH=[66]` cannot be found
# inside `WIDTH=[660]`, and never renders anything.
cat > "$shim/glow" <<'EOF'
#!/bin/sh
case "$1" in --version) printf 'glow version 3.0.0\n'; exit 0 ;; esac
w=none
while [ $# -gt 0 ]; do
  case "$1" in -w) w="$2"; shift ;; esac
  shift
done
printf 'WIDTH=[%s]\n' "$w"
EOF
# pager() asks `less --help` before paging, and it asks from inside the render
# pipeline -- so a less that reads stdin to answer --help swallows the render,
# and the real `less -R` after it gets EOF. It has to answer without reading.
cat > "$shim/less" <<'EOF'
#!/bin/sh
case "$1" in --help) exit 0 ;; esac
cat
EOF
chmod +x "$shim/glow" "$shim/less"

# ---- a terminal narrower than 80 ---------------------------------------------
# The case seen in practice: a 66-column tmux pane. The old code rendered it at
# 80 and less then folded every line again at 66.
out="$(PREEN_TTY_COLS=66 with_tty env PATH="$shim:$PATH" "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "WIDTH=[66]" "a named file on a 66-column terminal is rendered at 66"

# The same, with stderr sent away. Inside `$( )` stdout is a pipe, so a tput
# that can still find the terminal has found it on stderr -- ncurses 6.0 and
# later do, and the line above passed on them before the fix. This is the same
# terminal on stdout with nothing else to fall back to, and the old code said
# 80 here on every ncurses. The width has to come from where the render goes.
out="$(PREEN_TTY_COLS=66 with_tty env PATH="$shim:$PATH" \
  bash -c '"$1" "$2" 2>/dev/null' _ "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "WIDTH=[66]" "a named file with stderr elsewhere still measures stdout: 66"

# ---- and one wider ------------------------------------------------------------
# 80 is also what a tput that cannot see the terminal answers, so a wide pane
# is the other half of the proof: the number has to move with the terminal in
# both directions, not just stay under 80.
out="$(PREEN_TTY_COLS=132 with_tty env PATH="$shim:$PATH" "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "WIDTH=[132]" "a named file on a 132-column terminal is rendered at 132"

# ---- an explicit COLUMNS still wins --------------------------------------------
# ncurses honors $COLUMNS over the terminal's own size, so `COLUMNS=50 preen`
# already worked before the fix, and it is the one knob a person has to ask for
# a narrower render on a wide screen. Measuring the terminal must not take it
# away.
out="$(PREEN_TTY_COLS=66 with_tty env PATH="$shim:$PATH" COLUMNS=50 "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "WIDTH=[50]" "COLUMNS=50 on a 66-column terminal is rendered at 50"

# ---- no terminal at all --------------------------------------------------------
# `preen FILE.md | cat` with nothing on stdin or stderr either: there is no
# terminal to measure, and 80 is the answer, not an error and not an empty -w.
# stdin and stderr are closed off on purpose -- run by hand, a test inherits the
# developer's terminal on both, and the width would come from that.
out="$(env PATH="$shim:$PATH" "$PREEN" "$doc" </dev/null 2>/dev/null)"
assert_contains "$out" "WIDTH=[80]" "with no terminal anywhere the render falls back to 80"

# ---- the picker's enter key ----------------------------------------------------
# --show had its own `$(tput cols)`. fzf binds it as execute($SELF --show {}),
# which hands the child the real terminal, so the pty here is that key press.
st="$(preen_state md)" || exit 1
out="$(PREEN_TTY_COLS=66 with_tty env PATH="$shim:$PATH" PREEN_STATE="$st" "$PREEN" --show "$doc" | tr -d '\r')"
assert_contains "$out" "WIDTH=[66]" "enter on a 66-column terminal renders at 66"

# ---- piped input -----------------------------------------------------------------
# `cat FILE.md | preen` on a terminal: stdin is the pipe, so the width has to
# come from the terminal on stdout or stderr, and render_stdin measured it with
# the same `$(tput cols)` as the rest.
out="$(PREEN_TTY_COLS=66 with_tty env PATH="$shim:$PATH" \
  bash -c 'exec "$1" - < "$2"' _ "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "WIDTH=[66]" "piped markdown on a 66-column terminal renders at 66"
