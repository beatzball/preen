#!/usr/bin/env bash
# Drive the real picker in a PTY: list-only shims cannot prove selection survives.
set -u
. "$(dirname "$0")/lib.sh"
d="$(new_repo)" || exit 1; t=""
trap 'rm -rf "$d" "$t" "${_preen_dep_shim:-}"' EXIT
mktmpd t preen-watch
export XDG_STATE_HOME="$t/state"
mkdir "$t/old" "$t/live"
cat > "$t/old/fzf" <<'SH'
#!/bin/sh
case "${1:-}" in --version) printf '0.70.0\n'; exit 0 ;; esac
case " $* " in *--id-nth*) exit 2 ;; esac
cat >/dev/null
SH
chmod +x "$t/old/fzf"
out="$(cd "$d" && PATH="$t/old:$PATH" "$PREEN" watch 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; assert_true $? 'unsupported fzf rejects watch'
assert_contains "$out" 'watch needs fzf 0.73 or newer' 'unsupported fzf gets actionable version error'
assert_contains "$out" 'update fzf' 'unsupported fzf gets upgrade advice'
# The rejection precedes even the state directory, so no callback can poll.
mkdir "$t/no-state"
(cd "$d" && TMPDIR="$t/no-state" PATH="$t/old:$PATH" "$PREEN" watch >/dev/null 2>&1) || :
assert_eq "$(ls -A "$t/no-state")" '' 'unsupported watch creates neither state nor poller'

# 0.71 accepts --id-nth but drops background reload actions. Version gating
# must refuse it even though the capability probe alone would succeed.
cat > "$t/old/fzf" <<'SH'
#!/bin/sh
case "${1:-}" in --version) printf '0.71.0\n'; exit 0 ;; esac
exit 0
SH
out="$(cd "$d" && PATH="$t/old:$PATH" "$PREEN" watch 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; assert_true $? 'known broken fzf with --id-nth is rejected'
assert_contains "$out" 'watch needs fzf 0.73 or newer' 'known broken reload version gets upgrade advice'

# On older distro packages, exercise the real installed fzf rejection too.
if ! "$PREEN" --watch-check; then
  out="$(cd "$d" && "$PREEN" watch 2>&1)"; rc=$?
  [ "$rc" -ne 0 ]; assert_true $? 'installed old fzf rejects watch without opening a picker'
  assert_contains "$out" 'watch needs fzf 0.73 or newer' 'installed old fzf explains required capability'
  exit 0
fi
export WATCH_TEST="$t/live" WATCH_FZF="$(command -v fzf)" WATCH_DATE="$(command -v date)"
cat > "$t/live/fzf" <<'SH'
#!/bin/sh
printf '%s' "$PREEN_STATE" > "$WATCH_TEST/state"
printf '%s\n' "$$" > "$WATCH_TEST/fzf-pid"
export WATCH_PREEN="$PREEN_SELF" PREEN_SELF="$WATCH_TEST/callback"
exec "$WATCH_FZF" "$@" \
  --bind 'ctrl-t:execute-silent(printf "%s\000" {q} > "$WATCH_TEST/query"; cat "$PREEN_STATE/paths"/{1} > "$WATCH_TEST/selection")' \
  --bind 'ctrl-o:execute-silent(printf "%s:%s" "$FZF_TOTAL_COUNT" "$FZF_MATCH_COUNT" > "$WATCH_TEST/stats")' \
  --bind 'load:+execute-silent(printf . >> "$WATCH_TEST/loads")'
SH
cat > "$t/live/callback" <<'SH'
#!/bin/sh
case "${1:-}:${2:-}" in
  --review-file:edit)
    "$WATCH_PREEN" "$@" || exit $?
    if [ -f "$WATCH_TEST/hold-editor" ]; then
      : > "$WATCH_TEST/editor-held"
      while [ ! -f "$WATCH_TEST/release-editor" ]; do sleep 0.02; done
    fi ;;
  --review-file:viewed)
    "$WATCH_PREEN" "$@" || exit $?
    if [ -f "$WATCH_TEST/hold-viewed" ]; then
      : > "$WATCH_TEST/viewed-held"
      while [ ! -f "$WATCH_TEST/release-viewed" ]; do sleep 0.02; done
    fi ;;
  *) exec "$WATCH_PREEN" "$@" ;;
esac
SH
cat > "$t/live/date" <<'SH'
#!/bin/sh
if [ -f "$WATCH_TEST/hold-poll" ]; then
  : > "$WATCH_TEST/poll-held"
  while [ ! -f "$WATCH_TEST/release-poll" ]; do sleep 0.02; done
fi
exec "$WATCH_DATE" "$@"
SH
cat > "$t/live/vim" <<'SH'
#!/bin/sh
printf '%s\0' "$@" > "$WATCH_TEST/editor-args"
SH
export EDITOR="$t/live/vim"
chmod +x "$t/live/fzf" "$t/live/callback" "$t/live/date" "$t/live/vim"
PATH="$t/live:$PATH" python3 "$(dirname "$0")/watch-pty.py" "$d" "$t/live"
