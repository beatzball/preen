#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
d="$(new_repo)" || exit 1
box=""
trap 'rm -rf "$d" "$box" "${_preen_dep_shim:-}"' EXIT
mktmpd box preen-log
export LOG_BOX="$box" XDG_STATE_HOME="$box/state"
mkdir "$box/shim" "$box/capture"
root="$(git -C "$d" rev-parse HEAD)"
tgit -C "$d" checkout -qb feature
# Give the committed hunk a position well below the top of the file.
for n in {1..40}; do printf 'line %s\n' "$n"; done > "$d/f.txt"
tgit -C "$d" commit -qam baseline
sed '30s/.*/COMMITTED CHANGE/' "$d/f.txt" > "$box/content"
cp "$box/content" "$d/f.txt"
odd=$' space\tquote\047$(touch PREEN_INJECTED)\037line\nend '
printf 'ODD COMMITTED\n' > "$d/$odd"
printf 'wild literal\n' > "$d/*.txt"
printf '\000binary before' > "$d/binary"
tgit -C "$d" add -A
GIT_AUTHOR_DATE='2001-02-03T12:00:00Z' tgit -C "$d" commit -qm 'review $(touch PREEN_INJECTED)'
commit="$(git -C "$d" rev-parse HEAD)"
tgit -C "$d" checkout -qb side "$root"
printf 'SIDE COMMITTED\n' > "$d/side.txt"
tgit -C "$d" add .; tgit -C "$d" commit -qm side
tgit -C "$d" checkout -q feature
tgit -C "$d" merge -q --no-ff side -m merge
a_merge="$(git -C "$d" rev-parse HEAD)"
tgit -C "$d" commit -q --allow-empty -m empty
empty="$(git -C "$d" rev-parse HEAD)"
printf 'LOCAL ONLY\n' >> "$d/f.txt"
printf 'untracked\n' > "$d/local-only"
cat > "$box/shim/fzf" <<'PY'
#!/usr/bin/env python3
import os, pathlib, shlex, subprocess, sys
state = pathlib.Path(os.environ['PREEN_STATE'])
box = pathlib.Path(os.environ['LOG_BOX'])
out = box / 'capture'
kind = (state / 'kind').read_text().strip()
raw = sys.stdin.buffer.read()
args = sys.argv[1:]
if kind == 'log-list':
    (out / 'commits').write_bytes(raw)
    (out / 'commit-args').write_text('\n'.join(args))
    if (out / 'done').exists():
        sys.exit(0)
    (out / 'done').touch()
    sha = os.environ.get('LOG_SHA', '')
    row = next((r for r in raw.split(b'\0') if r.startswith(sha.encode() + b'\x1f')), None)
    if row is not None:
        preview = args[args.index('--preview') + 1].replace('{1}', shlex.quote(sha))
        (out / 'stat').write_bytes(subprocess.check_output(preview, shell=True))
        sys.stdout.buffer.write(row + b'\n')
else:
    (out / 'files').write_bytes(raw)
    (out / 'file-args').write_text('\n'.join(args))
    (out / 'target').write_bytes((state / 'target').read_bytes())
    (out / 'store').write_bytes((state / 'review-dir').read_bytes())
    rows = [r for r in raw.split(b'\0') if r]
    for row in rows:
        key, mark, path = row.split(b'\x1f', 2)
        selected = shlex.quote(key.decode())
        preview = args[args.index('--preview') + 1].replace('{1}', selected)
        (out / (key.decode() + '.diff')).write_bytes(subprocess.check_output(preview, shell=True))
        show = next(a for a in args if a.startswith('enter:execute('))[len('enter:execute('):-1]
        (out / (key.decode() + '.show')).write_bytes(subprocess.check_output(show.replace('{1}', selected), shell=True))
        if path == os.fsencode(os.environ.get('LOG_FILE', 'f.txt')):
            action = os.environ.get('LOG_ACTION', '')
            if action == 'viewed':
                bind = next(a for a in args if a.startswith('ctrl-v:reload-sync('))
                command = bind[len('ctrl-v:reload-sync('):-1]
                (out / 'after').write_bytes(subprocess.check_output(command.replace('{1}', selected), shell=True))
            elif action == 'edit':
                bind = next(a for a in args if a.startswith('ctrl-e:execute('))
                command = bind[len('ctrl-e:execute('):].split(')+reload-sync(', 1)[0]
                subprocess.check_call(command.replace('{1}', selected), shell=True)
PY
cat > "$box/shim/vim" <<'SH_EDITOR'
#!/bin/sh
printf '%s\0' "$@" > "$LOG_BOX/editor"
SH_EDITOR
chmod +x "$box/shim/fzf" "$box/shim/vim"
export EDITOR="$box/shim/vim" LOG_SHA="$commit" LOG_FILE=f.txt LOG_ACTION=''
log_run() {
  rm -rf "$box/capture"; mkdir "$box/capture"
  (cd "${LOG_CWD:-$d}" && PATH="$box/shim:$PATH" "$PREEN" log "$@" > "$box/out" 2> "$box/err")
}
log_names() {
  python3 "$PREEN_ROOT/tests/picker-paths.py" < "$box/capture/files" > "$box/names"
}
log_preview() {
  local key
  key="$(printf '%s' "$1" | git hash-object --stdin)"
  strip_ansi < "$box/capture/$key.diff"
}
before="$(snapshot "$d")"
log_run
assert_true $? 'default log range opens'
commits="$(tr '\0' '\n' < "$box/capture/commits")"
assert_contains "$commits" "${commit:0:12}" 'commit list shows abbreviated hash'
assert_contains "$commits" '2001-02-03' 'commit list shows author date'
assert_contains "$commits" '4 files' 'commit list counts every changed file'
assert_contains "$commits" 'review $(touch PREEN_INJECTED)' 'commit list preserves shell text as display'
assert_not_contains "$commits" "$root" 'default range excludes its merge-base'
assert_contains "$(strip_ansi < "$box/capture/stat")" '*.txt' 'commit preview includes stat'
log_names
list_has "$box/names" "$odd"; assert_true $? 'file list retains spaces, tabs, shell text, delimiter and newline'
assert_eq "$(list_count "$box/names")" 4 'file count agrees with commit file picker'
assert_contains "$(log_preview f.txt)" 'COMMITTED CHANGE' 'file preview renders committed content'
assert_not_contains "$(log_preview f.txt)" 'LOCAL ONLY' 'file preview excludes local edits'
assert_contains "$(log_preview '*.txt')" 'wild literal' 'glob filename previews its own diff'
assert_not_contains "$(log_preview '*.txt')" 'COMMITTED CHANGE' 'glob filename never expands to another committed path'
assert_contains "$(log_preview "$odd")" 'ODD COMMITTED' 'safe ID preview opens complete odd filename'
key="$(printf '%s' f.txt | git hash-object --stdin)"
assert_contains "$(strip_ansi < "$box/capture/$key.show")" 'COMMITTED CHANGE' 'enter renders the commit diff'
[ ! -d "$XDG_STATE_HOME" ]; assert_true $? 'browsing creates no persistent state'
assert_contains "$(cat "$box/capture/commit-args")" 'ctrl-e:ignore' 'commit list cannot open a SHA in the editor'
assert_contains "$(cat "$box/capture/file-args")" '--read0' 'file picker uses NUL framing'
mkdir "$d/sub"
LOG_CWD="$d/sub" log_run
assert_contains "$(log_preview f.txt)" 'COMMITTED CHANGE' 'log from a subdirectory resolves repository-root paths'
# origin/HEAD must take precedence over a local main with an older base.
git -C "$d" update-ref refs/remotes/origin/review-default "$commit"
git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/review-default
LOG_SHA="$a_merge" log_run
commits="$(tr '\0' '\n' < "$box/capture/commits")"
assert_not_contains "$commits" "$commit" 'default range prefers origin/HEAD over local main'
assert_contains "$commits" "$a_merge" 'default range retains commits since remote merge-base'
git -C "$d" symbolic-ref --delete refs/remotes/origin/HEAD
git -C "$d" update-ref -d refs/remotes/origin/review-default

LOG_ACTION=viewed log_run
assert_contains "$(cat "$box/capture/after" | tr '\0' '\n' | strip_ansi)" '✓' 'ctrl-v marks a committed file'
store="$(cat "$box/capture/store")"
python3 - "$box/capture/target" "$commit" <<'PY'
import pathlib, sys
fields = pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')
assert fields[1:] == [b'log', sys.argv[2].encode(), b''], fields
PY
assert_true $? 'review target is kind log and full immutable SHA'
printf 'MORE LOCAL ONLY\n' >> "$d/f.txt"
before="$(snapshot "$d")"
LOG_ACTION='' log_run "$commit^!"
assert_contains "$(tr '\0' '\n' < "$box/capture/files" | strip_ansi)" '✓' 'same SHA retains marks across ranges and local edits'
LOG_ACTION=viewed log_run "$commit^!"
assert_eq "$(find "$store" -name '*.viewed' | wc -l | tr -d ' ')" 0 'second ctrl-v unmarks the same committed file'
LOG_ACTION=edit log_run "$commit^!"
python3 - "$box/editor" <<'PY'
import pathlib, sys
assert pathlib.Path(sys.argv[1]).read_bytes() == b'+27\0f.txt\0'
PY
assert_true $? 'ctrl-e jumps to committed first hunk rather than local diff'
LOG_FILE="$odd" LOG_ACTION=edit log_run "$commit^!"
python3 - "$box/editor" "$odd" <<'PY'
import os, pathlib, sys
assert pathlib.Path(sys.argv[1]).read_bytes() == b'+1\0' + os.fsencode(sys.argv[2]) + b'\0'
PY
assert_true $? 'ctrl-e receives the complete odd filename safely'
[ ! -e "$d/PREEN_INJECTED" ]; assert_true $? 'shell text in subject and filename never executes'

LOG_SHA="$root" log_run "$root^!"
log_names
assert_eq "$(list_count "$box/names")" 1 'root commit lists its files against empty tree'
assert_contains "$(log_preview f.txt)" 'added: f.txt' 'root preview shows full file addition'
LOG_SHA="$a_merge" log_run "$a_merge^!"
log_names
assert_eq "$(list_count "$box/names")" 1 'merge file list compares only against first parent'
list_has "$box/names" side.txt; assert_true $? 'merge picker lists the incoming side file'
assert_contains "$(log_preview side.txt)" 'SIDE COMMITTED' 'merge preview compares against first parent'
LOG_SHA="$empty" log_run "$empty^!"
assert_eq "$(wc -c < "$box/capture/files" | tr -d ' ')" 0 'empty commit opens a truly empty file picker'
assert_contains "$(cat "$box/capture/file-args")" '0 of 0 viewed' 'empty commit header shows no files'
assert_eq "$(snapshot "$d")" "$before" 'log browsing, marks and editor callbacks write nothing to checkout'

log_run 'not-a-revision'
assert_eq $? 1 'invalid range exits with failure'
assert_contains "$(cat "$box/err")" 'invalid log range' 'invalid range explains the problem'
log_run '--all'
assert_eq $? 1 'range cannot inject a git option'
log_run 'HEAD..HEAD'
assert_eq $? 1 'empty range exits without opening a phantom row'
assert_contains "$(cat "$box/err")" 'nothing to show (log mode)' 'empty range explains the result'
mkdir "$box/unborn"
git init -q -b main "$box/unborn"
LOG_CWD="$box/unborn" log_run
assert_eq $? 1 'repository with no commits exits cleanly'
assert_contains "$(cat "$box/err")" 'nothing to show (log mode)' 'unborn repository explains empty history'
# No default branch means the bounded history fallback, including the root.
tgit -C "$d" branch -m main old-default
for n in {1..51}; do tgit -C "$d" commit -q --allow-empty -m "fallback $n"; done
LOG_SHA='' log_run
python3 - "$box/capture/commits" <<'PY'
import pathlib, sys
assert len([r for r in pathlib.Path(sys.argv[1]).read_bytes().split(b'\0') if r]) == 50
PY
assert_true $? 'missing default branch falls back to last 50 commits'
# A successfully inferred but empty range needs the same usable fallback.
mkdir "$box/default"
git init -q -b main "$box/default"
printf 'inherited\n' > "$box/default/inherited.txt"
printf '0\n' > "$box/default/changed.txt"
tgit -C "$box/default" add .; tgit -C "$box/default" commit -qm root
printf '1\n' > "$box/default/changed.txt"
tgit -C "$box/default" commit -qam first
printf '2\n' > "$box/default/changed.txt"
tgit -C "$box/default" commit -qam second
default_head="$(git -C "$box/default" rev-parse HEAD)"
LOG_CWD="$box/default" LOG_SHA='' log_run
assert_true $? 'bare log on main opens recent history'
assert_eq "$(list_count "$box/capture/commits")" 3 'bare log on main includes all three recent commits'
LOG_CWD="$box/default" log_run HEAD..HEAD
assert_eq $? 1 'explicit empty range stays empty on main'
tgit -C "$d" branch -m feature main
LOG_SHA='' log_run
assert_true $? 'bare log on main with long history opens'
assert_eq "$(list_count "$box/capture/commits")" 50 'empty inferred range fallback is capped at 50 commits'
tgit -C "$d" branch -m main feature

# Raw commit headers distinguish a shallow boundary from a genuine root.
git clone -q --depth=1 "file://$box/default" "$box/shallow"
git -C "$box/shallow" cat-file commit HEAD | grep -q '^parent '
assert_true $? 'shallow fixture has a real parent in its stored commit header'
git -C "$box/shallow" rev-parse --verify -q HEAD^ >/dev/null 2>&1
assert_eq $? 1 'shallow fixture cannot walk to its parent'
shallow_before="$(snapshot "$box/shallow")"
objects_before="$(git -C "$box/shallow" count-objects -v)"
boundary_before="$(cat "$box/shallow/.git/shallow")"
LOG_CWD="$box/shallow" LOG_SHA="$default_head" XDG_STATE_HOME="$box/shallow-state" log_run HEAD
assert_eq $? 1 'missing parent history rejects the range'
assert_contains "$(cat "$box/err")" 'missing first-parent history' 'shallow boundary gets a specific missing-history explanation'
assert_contains "$(cat "$box/err")" "${default_head:0:12}" 'missing-history response identifies the affected commit'
assert_contains "$(cat "$box/err")" 'preen does not fetch' 'missing-history response explains read-only behavior'
[ ! -e "$box/capture/commits" ]; assert_true $? 'missing history never opens a picker with fabricated counts'
[ ! -e "$box/shallow-state" ]; assert_true $? 'missing history creates no persistent review state'
assert_eq "$(snapshot "$box/shallow")" "$shallow_before" 'missing-history response preserves checkout files and index'
assert_eq "$(git -C "$box/shallow" count-objects -v)" "$objects_before" 'missing-history response downloads no objects'
assert_eq "$(cat "$box/shallow/.git/shallow")" "$boundary_before" 'missing-history response preserves shallow boundary'
# Callback errors must remain errors, including when creating viewed marks.
mkdir "$box/shallow-callback"
printf log > "$box/shallow-callback/kind"
printf '%s' "$default_head" > "$box/shallow-callback/commit"
printf inline > "$box/shallow-callback/mode"
: > "$box/shallow-callback/dir"
printf '%s\0log\0%s\0' "$box/shallow" "$default_head" > "$box/shallow-callback/target"
printf '%s' "$box/shallow-state/preen/target" > "$box/shallow-callback/review-dir"
(cd "$box/shallow" && PREEN_STATE="$box/shallow-callback" "$PREEN" --preview changed.txt > "$box/preview" 2> "$box/preview.err")
assert_eq $? 1 'missing-parent file preview propagates failure'
[ ! -s "$box/preview" ]; assert_true $? 'missing-parent file preview emits no root addition'
(cd "$box/shallow" && PREEN_STATE="$box/shallow-callback" "$PREEN" --viewed changed.txt > "$box/mark" 2> "$box/mark.err")
assert_eq $? 1 'missing-parent viewed hash propagates failure'
[ ! -e "$box/shallow-state" ]; assert_true $? 'missing-parent diff cannot be saved as viewed'
# The real picker tests level switches, empty selections and concurrent watch.
python3 "$PREEN_ROOT/tests/log-pty.py" "$d" "$box/pty" "$commit" "$empty" "$odd"
assert_true $? 'real fzf log levels handle filtering, empty commits, quit, viewed, edit and concurrent watch'
