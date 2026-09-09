#!/usr/bin/env bash
# preen FILE.md — rendering one named file, and whether it stays on screen.
#
# This path used to write its render and exit immediately. That is fine when a
# shell is waiting underneath, and wrong in a pane opened only to read the
# file: the command ends, so the pane closes before anyone reads a word. It now
# pages like piped input does, and must still write plain bytes into a pipe.
set -u
. "$(dirname "$0")/lib.sh"

# Both dependencies are shimmed, so the assertions are about preen's choices
# and never about how glow or less happen to format a page.
shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-file.XXXXXX")"
mark="$shim/pager"
doc="$shim/note.md"
# lib.sh sets its own EXIT trap for the glow version stub, and a second trap
# would replace it rather than add to it, so remove both here.
trap 'rm -rf "$shim" "${_preen_dep_shim:-}"' EXIT

printf '# Notes\n\nA paragraph.\n' > "$doc"

cat > "$shim/glow" <<'EOF'
#!/bin/sh
case "$1" in --version) printf 'glow version 3.0.0\n'; exit 0 ;; esac
# preen passes the file last, after -s and -w.
eval "f=\${$#}"
printf 'RENDERED %s\n' "$(basename "$f")"
EOF

cat > "$shim/less" <<EOF
#!/bin/sh
printf 'less %s' "\$*" > "$mark"
cat
EOF

chmod +x "$shim/glow" "$shim/less"

# ---- on a terminal -----------------------------------------------------------
# The pty is the whole point: `[ -t 1 ]` is what preen branches on, and a test
# harness only ever offers it a pipe.
out="$(PATH="$shim:$PATH"; export PATH; with_tty "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "RENDERED note.md" "a named file is rendered by glow"
assert_contains "$(cat "$mark" 2>/dev/null || echo none)" "less -R" \
  "on a terminal the render is held open by less -R"

# ---- into a pipe -------------------------------------------------------------
# No pager here, or `preen FILE.md | head` would hang on a full-screen program.
rm -f "$mark"
out="$(PATH="$shim:$PATH"; export PATH; "$PREEN" "$doc" 2>/dev/null)"
assert_contains "$out" "RENDERED note.md" "into a pipe the render still arrives"
[ ! -e "$mark" ]; assert_true $? "into a pipe no pager is started"

# ---- with no less on PATH ----------------------------------------------------
# pager() falls back to cat rather than running a less that is not there. The
# earlier version of this guard lost the whole render on such a machine.
#
# PATH is the shim alone, so `command -v less` genuinely fails. Everything
# preen reaches on this path is linked in beside the stubs; a missing one shows
# up as an empty render rather than a silent pass.
bare="$shim/bare"; mkdir -p "$bare"
ln -s "$shim/glow" "$bare/glow"
for b in bash tput cat sed dirname basename; do
  p="$(command -v "$b")" && ln -s "$p" "$bare/$b"
done
rm -f "$mark"
# env, not an exported PATH: the shim PATH is for preen alone. Exporting it
# would take tr and python3 away from the harness running the check.
out="$(with_tty env PATH="$bare" "$PREEN" "$doc" | tr -d '\r')"
assert_contains "$out" "RENDERED note.md" "with no less installed the render still arrives"

# ---- the glow gate -----------------------------------------------------------
# Every other renderer calls need_glow. This branch did not, so a machine
# without glow got "glow: command not found" instead of preen saying so.
out="$(PATH=/usr/bin:/bin "$PREEN" "$doc" 2>&1 || true)"
assert_contains "$out" "glow is not installed" "a named file refuses without glow"

old="$shim/old"; mkdir -p "$old"
cat > "$old/glow" <<'EOF'
#!/bin/sh
case "$1" in --version) printf 'glow version 2.0.0\n'; exit 0 ;; esac
EOF
chmod +x "$old/glow"
out="$(PATH="$old:/usr/bin:/bin"; export PATH; "$PREEN" "$doc" 2>&1 || true)"
assert_contains "$out" "glow 3 or newer" "a named file refuses an old glow"

# ---- a file that is not there ------------------------------------------------
out="$(PATH="$shim:$PATH"; export PATH; "$PREEN" "$shim/absent.md" 2>&1 || true)"
assert_contains "$out" "no such file" "a missing file is refused by name"
[ ! -e "$mark" ]; assert_true $? "a missing file starts no pager"
