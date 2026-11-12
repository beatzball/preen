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
export WATCH_TEST="$t/live" WATCH_FZF="$(command -v fzf)"
cat > "$t/live/fzf" <<'SH'
#!/bin/sh
printf '%s' "$PREEN_STATE" > "$WATCH_TEST/state"
printf '%s\n' "$$" > "$WATCH_TEST/fzf-pid"
exec "$WATCH_FZF" "$@" \
  --bind 'ctrl-t:execute-silent(cat "$PREEN_STATE/paths"/{1} > "$WATCH_TEST/selection"; printf "%s\000" {q} > "$WATCH_TEST/query")' \
  --bind 'load:+execute-silent(printf . >> "$WATCH_TEST/loads")'
SH
chmod +x "$t/live/fzf"
PATH="$t/live:$PATH" python3 "$(dirname "$0")/watch-pty.py" "$d" "$t/live"
