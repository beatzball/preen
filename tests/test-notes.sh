#!/usr/bin/env bash
# Drive the actual note binding, store and exports, with disposable fixtures.
set -u
. "$(dirname "$0")/lib.sh"
mktmpd box preen-notes
mktmpd shim preen-notes-shim
d="$(new_repo)" || exit 1
other="$(new_repo)" || exit 1
trap 'rm -rf "$box" "$shim" "$d" "$other" "${_preen_dep_shim:-}"' EXIT
export XDG_STATE_HOME="$box/state" NOTE_BOX="$box" NOTE_FILE=f.txt NOTE_TEXT='Fix this branch.' NOTE_ACTION=note
export EDITOR="$shim/editor"
cat > "$shim/editor" <<'EDITOR'
#!/bin/sh
printf '%s' "$1" > "$NOTE_BOX/editor-path"
cat "$1" > "$NOTE_BOX/editor-before"
[ "${NOTE_FAIL:-0}" = 0 ] || exit 1
printf '%s' "$NOTE_TEXT" > "$1"
EDITOR
cat > "$shim/fzf" <<'PY'
#!/usr/bin/env python3
import os, pathlib, shlex, subprocess, sys
box = pathlib.Path(os.environ['NOTE_BOX'])
state = pathlib.Path(os.environ['PREEN_STATE'])
raw = sys.stdin.buffer.read()
args = sys.argv[1:]
if (state / 'kind').read_text().strip() == 'wt':
    if (box / 'entered').exists():
        sys.exit(0)
    (box / 'entered').touch()
    sys.stdout.buffer.write(raw.split(b'\0')[0] + b'\n')
    sys.exit(0)
(box / 'initial').write_bytes(raw)
(box / 'argv').write_text('\n'.join(args))
(box / 'store').write_text((state / 'review-dir').read_text() if (state / 'review-dir').exists() else '')
action = os.environ['NOTE_ACTION']
if action == 'none':
    sys.exit(0)
key = 'ctrl-n:' if action == 'note' else 'ctrl-v:'
bind = next((a for a in args if a.startswith(key)), '')
if not bind:
    (box / 'rc').write_text('missing binding')
    sys.exit(0)
row = next(r for r in raw.split(b'\0') if r.split(b'\x1f', 2)[-1] == os.fsencode(os.environ['NOTE_FILE']))
id = shlex.quote(row.split(b'\x1f', 1)[0].decode())
if action == 'note':
    command = bind[len(key + 'execute('):].split(')+reload-sync(', 1)[0]
else:
    command = bind[len(key + 'reload-sync('):-1]
result = subprocess.run(command.replace('{1}', id), shell=True, capture_output=True)
(box / 'rc').write_text(str(result.returncode))
(box / 'error').write_bytes(result.stderr)
result = subprocess.run('"$PREEN_SELF" --review-list', shell=True, capture_output=True)
(box / 'after').write_bytes(result.stdout)
PY
cat > "$shim/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  'auth status') exit 0 ;;
  'pr view') printf '%s\tReview\n' "$3" ;;
  'pr diff')
    case "${4:-}" in --name-only) printf 'z.txt\nf.txt\n' ;; *) cat "$NOTE_BOX/pr.diff" ;; esac ;;
  *) exit 1 ;;
esac
GH
chmod +x "$shim/editor" "$shim/fzf" "$shim/gh"
notes_run() {
  local cwd="$1"; export NOTE_ACTION="$2"; shift 2
  rm -f "$box/entered" "$box/rc" "$box/error" "$box/editor-path"
  (cd "$cwd" && PATH="$shim:$PATH" "$PREEN" "$@" > "$box/stdout" 2> "$box/stderr")
  printf '%s' "$?" > "$box/app-rc"
}
notes_export() {
  local cwd="$1"; shift
  (cd "$cwd" && PATH="$shim:$PATH" "$PREEN" notes "$@" > "$box/export" 2> "$box/export-error")
}
notes_marked() {
  python3 - "$box/$1" "$NOTE_FILE" <<'PY'
import os, sys
rows = open(sys.argv[1], 'rb').read().split(b'\0')
sys.exit(0 if any(len(f := r.split(b'\x1f', 2)) == 3 and f[2] == os.fsencode(sys.argv[2]) and '✎'.encode() in f[1] for r in rows) else 1)
PY
}
printf 'changed\n' >> "$d/f.txt"
printf 'last\n' > "$d/z.txt"
before="$(snapshot "$d")"
notes_run "$d" none diff
[ ! -d "$XDG_STATE_HOME" ]; assert_true $? 'browsing creates no note store'
notes_export "$d" diff
assert_eq "$(cat "$box/export")" '' 'export without notes is empty'
notes_run "$d" note diff
assert_eq "$(cat "$box/rc")" 0 'actual ctrl-n binding saves a note'
[ "$(cat "$box/rc")" = 0 ] || exit 1
notes_marked after; assert_true $? 'note has a separate pencil mark'
store="$(cat "$box/store")"
assert_eq "$(cat "$store/files/"*.note)" "$NOTE_TEXT" 'note uses reserved per-file slot'
assert_eq "$(find "$store/files" -name '*.viewed' | wc -l | tr -d ' ')" 0 'notes do not mark files viewed'
case "$(cat "$box/editor-path")" in "$store"/*|"$d"/*) good=1 ;; *) good=0 ;; esac
assert_eq "$good" 0 'editor gets a temporary buffer outside store and checkout'
notes_run "$d" none diff
notes_marked initial; assert_true $? 'note survives reopening'
notes_run "$d" note diff
assert_eq "$(cat "$box/editor-before")" "$NOTE_TEXT" 'editing again starts with saved note'
export NOTE_FAIL=1 NOTE_TEXT='Discard this.'
notes_run "$d" note diff
assert_eq "$(cat "$box/rc")" 1 'failed editor reports failure'
assert_eq "$(cat "$store/files/"*.note)" 'Fix this branch.' 'failed editor preserves saved note'
export NOTE_FAIL=0 NOTE_TEXT='Second file.' NOTE_FILE=z.txt
notes_run "$d" note diff
notes_export "$d" diff
assert_eq "$(cat "$box/export")" $'## f.txt\nFix this branch.\n\n## z.txt\nSecond file.' 'export is plain Markdown in list order'
notes_export "$d"
assert_eq "$(cat "$box/export")" $'## f.txt\nFix this branch.\n\n## z.txt\nSecond file.' 'bare notes exports working-tree review'
export NOTE_FILE=f.txt NOTE_TEXT=''
notes_run "$d" viewed diff
notes_run "$d" note diff
notes_marked after; assert_eq $? 1 'empty editor buffer clears note mark'
notes_export "$d" diff
assert_eq "$(cat "$box/export")" $'## z.txt\nSecond file.' 'cleared note leaves no export section'
[ -s "$store/files/"*.viewed ]; assert_true $? 'clearing note preserves viewed mark'
export NOTE_TEXT='Revision note.'
notes_run "$d" note diff HEAD
notes_export "$d" diff HEAD
assert_contains "$(cat "$box/export")" 'Revision note.' 'explicit revision export uses separate target'
notes_export "$d" diff
assert_not_contains "$(cat "$box/export")" 'Revision note.' 'revision note does not leak to working tree'
# Filenames are data even when they contain shell text and separator bytes.
export NOTE_FILE=$'odd\037\tline\n$(touch PREEN_INJECTION).txt' NOTE_TEXT='Odd path note.'
printf 'odd\n' > "$d/$NOTE_FILE"
notes_run "$d" note diff
assert_eq "$(cat "$box/rc")" 0 'unusual filename note saves through safe ID'
notes_run "$d" none diff
notes_marked initial; assert_true $? 'unusual filename note survives restart'
[ ! -e "$d/PREEN_INJECTION" ]; assert_true $? 'filename shell text never executes'
rm "$d/$NOTE_FILE"
notes_export "$d" diff
assert_contains "$(cat "$box/export")" 'Odd path note.' 'note survives a path leaving the diff'
assert_eq "$(snapshot "$d")" "$before" 'all note operations leave checkout untouched'
# Notes follow a path when its content changes, independently of viewed hashes.
export NOTE_FILE=f.txt NOTE_TEXT='Persistent feedback.'
notes_run "$d" note diff
printf 'new change\n' >> "$d/f.txt"
notes_run "$d" none diff
notes_marked initial; assert_true $? 'changed diff preserves note'
cat > "$box/pr.diff" <<'DIFF'
diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1 +1 @@
-old
+new
DIFF
before="$(snapshot "$d")"
export NOTE_TEXT='PR first.' NOTE_FILE=z.txt
notes_run "$d" note pr 42
export NOTE_TEXT='PR second.' NOTE_FILE=f.txt
notes_run "$d" note pr 42
notes_export "$d" pr 42
assert_eq "$(cat "$box/export")" $'## z.txt\nPR first.\n\n## f.txt\nPR second.' 'PR export follows API list order'
notes_run "$d" none pr 42
notes_marked initial; assert_true $? 'PR note survives reopening'
notes_export "$d" pr 43
assert_eq "$(cat "$box/export")" '' 'PR numbers have distinct notes'
assert_eq "$(snapshot "$d")" "$before" 'PR note editing and export leave checkout untouched'
# The worktree target is distinct from diff within that same checkout.
tgit -C "$d" worktree add -qb review "$box/wt" HEAD
printf 'worktree change\n' >> "$box/wt/f.txt"
before="$(snapshot "$box/wt")"
export NOTE_TEXT='Worktree feedback.'
notes_run "$d" note wt
notes_run "$d" none wt
notes_marked initial; assert_true $? 'worktree note survives reopening'
notes_export "$d" wt "$box/wt"
assert_eq "$(cat "$box/export")" $'## f.txt\nWorktree feedback.' 'worktree target exports without opening picker'
notes_export "$box/wt" diff
assert_eq "$(cat "$box/export")" '' 'local diff and worktree notes are separate'
assert_eq "$(snapshot "$box/wt")" "$before" 'worktree remains untouched'
# Refuse stores inside any checkout, even another repository or symlink target.
for location in "$d/state" "$other/state" "$other/.git/state" "$box/wt/state"; do
  export XDG_STATE_HOME="$location"
  notes_run "$d" note diff
  assert_eq "$(cat "$box/rc")" 1 'state home in a checkout is refused'
  [ ! -e "$location" ]; assert_true $? 'refused checkout location creates no state'
done
export XDG_STATE_HOME="$box/link-state"
ln -s "$other/new-state" "$XDG_STATE_HOME"
notes_run "$d" note diff
assert_eq "$(cat "$box/rc")" 1 'dangling symlink into another checkout is refused'
[ ! -e "$other/new-state" ]; assert_true $? 'dangling state link creates no checkout files'
# A missing path component before .. must not hide a later checkout symlink.
ln -s "$other" "$box/checkout-alias"
export XDG_STATE_HOME="$box/missing/../checkout-alias/state"
notes_run "$d" note diff
assert_eq "$(cat "$box/rc")" 1 'missing/../checkout state destination is refused'
[ ! -e "$other/state" ]; assert_true $? 'missing/../checkout creates no state'
export XDG_STATE_HOME="$box/state" NOTE_TEXT='Safe note.'
notes_run "$d" note diff
store="$(cat "$box/store")"
key="$(printf '%s' "$NOTE_FILE" | git hash-object --stdin)"
rm "$store/files/$key.note"
ln -s "$other/f.txt" "$store/files/$key.note"
before="$(snapshot "$other")"
notes_run "$d" note diff
assert_eq "$(cat "$box/app-rc")" 1 'note symlink into checkout is refused'
assert_eq "$(snapshot "$other")" "$before" 'note symlink does not write checkout'
rm "$store/files/$key.note"
# A real PTY proves empty selection, filtering and watch/editor interleaving.
python3 "$PREEN_ROOT/tests/notes-picker.py" "$other" "$box/real"
assert_true $? 'real fzf note editing, empty selection, filtered reloads and watch races'
