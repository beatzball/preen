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
trap 'rm -rf "$shim"' EXIT

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

( PATH="$shim:$PATH"; export PATH; "$PREEN" "$doc" >/dev/null 2>&1 )
assert_true $? "rendering one file exits 0"

# ---- a file that is not there ------------------------------------------------
out="$(PATH="$shim:$PATH"; export PATH; "$PREEN" "$shim/absent.md" 2>&1 || true)"
assert_contains "$out" "no such file" "a missing file is refused by name"
[ ! -e "$mark" ]; assert_true $? "a missing file starts no pager"
