# tests/lib.sh — minimal bash test harness. No framework.
#
# Sourced by tests/test-*.sh. Needs: git, and whatever the test itself drives.
#
# Every test builds its own throwaway repository under $TMPDIR and removes it
# on exit, so nothing here touches the checkout it is run from — which matters
# more than usual, because half of what preen does is read the repository it is
# standing in.
: "${PREEN_TESTS_PASS:=0}"
: "${PREEN_TESTS_FAIL:=0}"

# The preen under test is always the one in this checkout, never whatever is on
# the developer's PATH. Without this a test would silently grade the installed
# copy, which is the one case where a green suite means nothing.
PREEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREEN="$PREEN_ROOT/bin/preen"
export PREEN_ROOT PREEN

# ---- assertions -------------------------------------------------------------

assert_eq() {
  if [ "$1" = "$2" ]; then
    PREEN_TESTS_PASS=$((PREEN_TESTS_PASS+1)); printf '  PASS: %s\n' "$3"
  else
    PREEN_TESTS_FAIL=$((PREEN_TESTS_FAIL+1)); printf '  FAIL: %s\n       want [%s] got [%s]\n' "$3" "$2" "$1"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) PREEN_TESTS_PASS=$((PREEN_TESTS_PASS+1)); printf '  PASS: %s\n' "$3" ;;
    *)      PREEN_TESTS_FAIL=$((PREEN_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) PREEN_TESTS_FAIL=$((PREEN_TESTS_FAIL+1)); printf '  FAIL: %s\n       [%s] contains [%s]\n' "$3" "$1" "$2" ;;
    *)      PREEN_TESTS_PASS=$((PREEN_TESTS_PASS+1)); printf '  PASS: %s\n' "$3" ;;
  esac
}

assert_true() {
  # assert_true <exit-status> <label>
  # Pass the status of the command under test, taken immediately before the
  # call: `[ -n "$x" ]; assert_true $? "x is set"`. Written this way rather
  # than as `assert_eq ok ok` inside an if, because that shape prints a PASS
  # line that is not evidence of the thing it names.
  if [ "$1" -eq 0 ] 2>/dev/null; then
    PREEN_TESTS_PASS=$((PREEN_TESTS_PASS+1)); printf '  PASS: %s\n' "$2"
  else
    PREEN_TESTS_FAIL=$((PREEN_TESTS_FAIL+1)); printf '  FAIL: %s\n       exit status was [%s], wanted 0\n' "$2" "$1"
  fi
}

assert_nonempty() {
  if [ -n "$1" ]; then
    PREEN_TESTS_PASS=$((PREEN_TESTS_PASS+1)); printf '  PASS: %s\n' "$2"
  else
    PREEN_TESTS_FAIL=$((PREEN_TESTS_FAIL+1)); printf '  FAIL: %s\n       value was empty\n' "$2"
  fi
}

# ---- fixtures ---------------------------------------------------------------

# Commit without depending on the developer's git identity, and without writing
# to their config.
#
# Named tgit, not g: `g` is a common interactive alias for git, and a shell
# that has one refuses to define a function over it — which breaks sourcing
# this file by hand to poke at a fixture.
tgit() { git -c user.name=preen-test -c user.email=test@example.com "$@"; }

new_repo() {
  # new_repo -> prints the path of a fresh repo with one commit
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/preen-test.XXXXXX")"
  git init -q -b main "$d"
  printf 'base\n' > "$d/f.txt"
  tgit -C "$d" add -A; tgit -C "$d" commit -qm init
  printf '%s\n' "$d"
}

# ---- driving preen ----------------------------------------------------------
#
# preen's picker is fzf, which cannot be driven headlessly. But the file list
# and every preview are computed by preen itself and reachable without it: the
# list through the same commands the script runs, and the previews through the
# `--preview` and `--show` callbacks fzf itself invokes.
#
# So the tests drive those callbacks directly. That is not a workaround — it is
# the same entry point fzf uses, with the same $PREEN_STATE contract.

preen_state() {
  # preen_state <kind> [mode] [rev] [dir] -> prints a state dir
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/preen-state.XXXXXX")"
  printf '%s' "${1:-diff}"  > "$d/kind"
  printf '%s' "${2:-sbs}"   > "$d/mode"
  printf '%s' "${3:-}"      > "$d/rev"
  printf '%s' "${4:-}"      > "$d/dir"
  printf '%s\n' "$d"
}

preview() {
  # preview <state-dir> <target> -> the preview fzf would show, ANSI stripped
  PREEN_STATE="$1" FZF_PREVIEW_COLUMNS="${FZF_PREVIEW_COLUMNS:-100}" \
    "$PREEN" --preview "$2" 2>/dev/null | strip_ansi
}

strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*[a-zA-Z]//g"; }

# ---- read-only proof --------------------------------------------------------
#
# The docs claim pr and worktrees modes never write. Asserting "no checkout
# happened" by eye is not a test; this snapshots enough to catch any write.

snapshot() {
  # snapshot <dir> -> one string covering HEAD, the index, and every file
  local d="$1"
  {
    git -C "$d" rev-parse HEAD 2>/dev/null
    git -C "$d" status --porcelain 2>/dev/null
    git -C "$d" stash list 2>/dev/null
    # Content, not just names: a rewritten file with the same name would
    # otherwise slip past.
    find "$d" -type f -not -path '*/.git/*' -exec shasum {} + 2>/dev/null | sort
  }
}

# ---- capturing the real file list -------------------------------------------
#
# preen builds $FILES and pipes it straight into fzf, so there is no flag that
# prints it. Reimplementing the same git commands in a test would grade the
# copy in the test rather than the code, and would keep passing after bin/preen
# changed underneath it.
#
# So put a fake `fzf` first on PATH that writes its stdin out and exits. What
# that captures is exactly the list the real picker would have been given.

preen_list_raw() {
  # preen_list_raw <outfile> <cwd> <preen args...>
  #   -> the exact bytes preen hands fzf, written to <outfile>
  #
  # A file, not a string, because the list is NUL-delimited and a filename may
  # contain a newline: bash cannot hold a NUL, and "$(...)" would drop the
  # separators and glue two names into one.
  local out="$1" cwd="$2"; shift 2
  local shim
  shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-shim.XXXXXX")"
  # Truncate both, so a run that dies before reaching fzf leaves an empty list
  # rather than the previous call's one for the next assertions to grade.
  : > "$out"; : > "$out.argv"
  cat > "$shim/fzf" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$out.argv"
cat > "$out"
exit 0
EOF
  chmod +x "$shim/fzf"
  ( cd "$cwd" && PATH="$shim:$PATH" "$PREEN" "$@" >/dev/null 2>&1 )
  rm -rf "$shim"
}

preen_list_raw2() {
  # preen_list_raw2 <outfile> <cwd> <preen args...>
  #   -> the SECOND list preen builds, plus the flags that went with it
  #
  # worktrees mode has two levels, and the shim above only ever sees the first:
  # it prints nothing, so `sel` comes back empty and the loop stops. This shim
  # accepts the first record instead, which is what drives preen into level two,
  # and captures that list and its flags. The third call returns nothing so the
  # loop ends rather than cycling for ever.
  #
  # The record is fed back a line at a time, so this seam cannot drive a
  # worktree whose own directory name contains a newline. The files inside one
  # are what it is for, and those it carries whole.
  local out="$1" cwd="$2"; shift 2
  local shim
  shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-shim2.XXXXXX")"
  : > "$out"; : > "$out.argv"; rm -f "$out.n"
  cat > "$shim/fzf" <<EOF
#!/bin/sh
n=\$(cat "$out.n" 2>/dev/null || echo 0)
n=\$((n + 1)); printf '%s' "\$n" > "$out.n"
case "\$n" in
  1) cat > "$out.level1"
     # the record fzf would print on enter: label, a tab, then the path
     tr '\0' '\n' < "$out.level1" | head -n 1 ;;
  2) printf '%s\n' "\$@" > "$out.argv"
     cat > "$out" ;;
  *) cat > /dev/null ;;
esac
exit 0
EOF
  chmod +x "$shim/fzf"
  ( cd "$cwd" && PATH="$shim:$PATH" "$PREEN" "$@" >/dev/null 2>&1 )
  rm -rf "$shim"
}

list_bind() {
  # list_bind <raw-list-file> <key> -> the --bind preen set for that key
  list_flags "$1" | sed -n "s/^$2://p"
}

list_flags() {
  # list_flags <raw-list-file> -> the arguments preen gave fzf, one per line
  #
  # The list being NUL-framed is only half of it: fzf splits on newline unless
  # it is told otherwise, so a name containing one arrives as two entries even
  # from a perfect list. Nothing else in the suite can see a flag, because the
  # shim stands where fzf would.
  cat "$1.argv" 2>/dev/null
}

preen_list() {
  # preen_list <cwd> <preen args...> -> the list preen hands fzf, one per line
  #
  # For the many names that hold no newline this is the readable form. A test
  # about a name that does hold one wants preen_list_raw and list_has.
  local cwd="$1"; shift
  local raw; raw="$(mktemp "${TMPDIR:-/tmp}/preen-list.XXXXXX")"
  preen_list_raw "$raw" "$cwd" "$@"
  tr '\0' '\n' < "$raw"
  rm -f "$raw" "$raw".*          # the recorded flags go with it
}

# ---- asking a NUL-delimited list about one name -----------------------------
#
# python3 rather than grep or awk: the entries are separated by NUL and one of
# them contains a newline, which is exactly the pair of bytes the line-oriented
# tools cannot both handle. It is already a dependency of with_tty below.

list_names_py='
import sys, os
try:
    raw = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(1)
names = [n for n in raw.split(b"\0") if n]
'

list_has() {
  # list_has <raw-list-file> <name> -> exit 0 if the list holds exactly <name>
  python3 -c "$list_names_py"'
sys.exit(0 if os.fsencode(sys.argv[2]) in names else 1)
' "$1" "$2"
}

list_holds_name() {
  # list_holds_name <raw-list-file> <name>
  #   -> exit 0 if the name's own bytes appear in the list, as they are
  #
  # Deliberately blind to WHICH byte separates the entries -- NUL or newline --
  # so it asks only whether git escaped the name. That is the half of the bug
  # `-z` fixes, and a quote or a backslash fails it on its own, whatever the
  # framing. It does insist on a boundary at each end: without that,
  # `plain.txt` would be found inside `untracked-plain.txt` and the assertion
  # would pass for the wrong entry.
  python3 -c '
import sys, os
try:
    raw = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(1)
n = os.fsencode(sys.argv[2])
i = raw.find(n)
while i != -1:
    before = i == 0 or raw[i-1:i] in (b"\0", b"\n")
    j = i + len(n)
    after = j == len(raw) or raw[j:j+1] in (b"\0", b"\n")
    if before and after:
        sys.exit(0)
    i = raw.find(n, i + 1)
sys.exit(1)
' "$1" "$2"
}

list_in_order() {
  # list_in_order <raw-list-file> -> exit 0 if the entries are in byte order
  #
  # The picker shows the list in the order preen hands it over, and preen sorts
  # it. `sort -u` on a NUL-delimited stream sees one enormous line and sorts
  # nothing, so this is what notices a `-z` going missing from a sort.
  python3 -c "$list_names_py"'
sys.exit(0 if names == sorted(names) else 1)
' "$1"
}

list_count() {
  # list_count <raw-list-file> -> how many entries the list holds
  python3 -c "$list_names_py"'
print(len(names))
' "$1"
}

# ---- satisfying preen's dependency gates ------------------------------------
#
# preen refuses to start without glow 3, and every mode checks for delta and
# fzf. No test in this suite asserts on glow's OUTPUT — the diff previews go
# through delta, and test-stdin.sh shims both renderers itself — so a stub that
# answers the version check is enough, and it keeps glow off the CI runner.
#
# delta and fzf are NOT stubbed here: several tests assert on rendered diff
# content, and fzf is stubbed per-call by preen_list where it matters.
_preen_dep_shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-dep.XXXXXX")"
if ! command -v glow >/dev/null 2>&1; then
  cat > "$_preen_dep_shim/glow" <<'EOF'
#!/bin/sh
# Version-only stub. Anything that actually renders markdown in a test brings
# its own shim, so reaching this path with real arguments means a test is
# depending on glow output it should be asserting some other way.
case "$1" in --version) printf 'glow version 3.0.0\n'; exit 0 ;; esac
cat > /dev/null
EOF
  chmod +x "$_preen_dep_shim/glow"
  PATH="$_preen_dep_shim:$PATH"
  export PATH
fi
trap 'rm -rf "$_preen_dep_shim"' EXIT

# ---- running preen on a real terminal ---------------------------------------
#
# preen decides whether to page by asking `[ -t 1 ]`, so the paging tests need
# stdout to be a terminal. A test harness has a pipe. `script` cannot help:
# it wants a terminal on stdin too, which CI does not have either.
#
# So allocate a pty directly and hand the child its slave end. python3 is on
# both the macOS and the ubuntu runners; if it is missing the tests fail loudly
# rather than skipping, because a silently skipped paging test is the one that
# lets this regress.

# The timeout is not decoration. A pty stays readable while ANY process holds
# the slave end, so one stray background child makes the read loop wait for
# ever -- and the CI job it would hang in has no time limit of its own.
PREEN_TTY_TIMEOUT="${PREEN_TTY_TIMEOUT:-30}"
export PREEN_TTY_TIMEOUT

with_tty() {
  # with_tty <cmd> [args...] -> what the command wrote to a terminal, stdout
  # and stderr together, exactly as a person at a terminal would see them.
  # Exits 124 if the command outlived PREEN_TTY_TIMEOUT seconds.
  python3 - "$@" <<'PY'
import os, pty, select, subprocess, sys, time
deadline = time.monotonic() + float(os.environ.get("PREEN_TTY_TIMEOUT", "30"))
master, slave = pty.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL,
                     stdout=slave, stderr=slave)
os.close(slave)
out, timed_out = b"", False
while True:
    left = deadline - time.monotonic()
    if left <= 0:
        timed_out = True
        break
    if not select.select([master], [], [], left)[0]:
        continue
    try:
        chunk = os.read(master, 65536)
    except OSError:  # the pty raises EIO instead of EOF when the child exits
        break
    if not chunk:
        break
    out += chunk
os.close(master)
if timed_out:
    p.kill()
    sys.stderr.write("with_tty: timed out\n")
p.wait()
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(124 if timed_out else p.returncode)
PY
}
