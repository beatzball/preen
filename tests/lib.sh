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

preen_list() {
  # preen_list <cwd> <preen args...> -> the list preen hands fzf, one per line
  local cwd="$1"; shift
  local shim out
  shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-shim.XXXXXX")"
  out="$shim/list"
  cat > "$shim/fzf" <<EOF
#!/bin/sh
cat > "$out"
exit 0
EOF
  chmod +x "$shim/fzf"
  ( cd "$cwd" && PATH="$shim:$PATH" "$PREEN" "$@" >/dev/null 2>&1 )
  cat "$out" 2>/dev/null
  rm -rf "$shim"
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
