#!/usr/bin/env bash
# Drive the real editor callback and fzf binding; fake editors record NUL argv.
set -u
. "$(dirname "$0")/lib.sh"
d="$(new_repo)" || exit 1
s="$(preen_state diff)" || exit 1
mktmpd box preen-editor
trap 'rm -rf "$d" "$s" "$box" "${_preen_dep_shim:-}"' EXIT
mkdir -p "$box/bin"
cat > "$box/bin/record" <<'ED'
#!/bin/sh
printf '%s\0' "$@" >> "$PREEN_EDITOR_LOG"
if [ "${PREEN_REJECT_JUMP:-}" = 1 ]; then
  case "$1" in +*|--goto|*:17) exit 2 ;; esac
fi
ED
chmod +x "$box/bin/record"
for name in vi vim nvim nano emacs emacsclient micro hx helix code code-insiders zed unknown vim-wrapper; do
  ln -s record "$box/bin/$name"
done
mkdir "$box/editor space"
ln -s "$box/bin/record" "$box/editor space/vim"
export PREEN_EDITOR_LOG="$box/argv"

expect_args() {
  local label="$1"; shift
  printf '%s\0' "$@" > "$box/expected"
  cmp -s "$PREEN_EDITOR_LOG" "$box/expected"
  assert_true $? "$label"
}
edit() {
  : > "$PREEN_EDITOR_LOG"
  ( cd "$d" && PREEN_STATE="$s" EDITOR="$editor" "$PREEN" --edit "$file" "${open_path:-$file}" ) </dev/null >/dev/null 2>&1
  assert_true $? "editor callback succeeds: $label"
}
# Context starts at 17 for a change at 20. A later hunk must not win, and the
# first edit is staged while the second remains unstaged.
for n in $(seq 1 80); do printf 'line %s\n' "$n"; done > "$d/long.txt"
tgit -C "$d" add long.txt; tgit -C "$d" commit -qm baseline
sed '20s/.*/staged change/' "$d/long.txt" > "$box/edited"
cp "$box/edited" "$d/long.txt"
tgit -C "$d" add long.txt
sed '60s/.*/unstaged change/' "$d/long.txt" > "$box/edited"
cp "$box/edited" "$d/long.txt"
file=long.txt; open_path=""
for name in vi vim nvim nano emacs emacsclient micro hx helix; do
  editor="$box/bin/$name"; label="$name first hunk"
  edit
  expect_args "$label uses +17 and one intact filename" +17 long.txt
done
editor="$box/bin/code --wait"; label='VS Code with options'; edit
expect_args "$label preserves options and uses --goto" --wait --goto long.txt:17
editor="$box/bin/code-insiders"; label='VS Code Insiders'; edit
expect_args "$label uses --goto" --goto long.txt:17
editor="$box/bin/zed"; label=Zed; edit
expect_args "$label uses path:line" long.txt:17
editor="$box/editor space/vim"; label='editor executable path with spaces'; edit
expect_args "$label stays one command" +17 long.txt
for name in unknown vim-wrapper; do
  editor="$box/bin/$name --wait"; label="$name fallback"; edit
  expect_args "$label gets no guessed jump flag" --wait long.txt
done
editor="$box/bin/vim"; label='jump rejection'
PREEN_REJECT_JUMP=1 edit
expect_args 'a rejected jump retries the plain file' +17 long.txt long.txt

# REV changes the comparison; Markdown ignores it entirely.
printf 'md' > "$s/kind"
label='Markdown'; edit
expect_args 'Markdown opens plainly even in a dirty repository' long.txt
printf 'diff' > "$s/kind"
tgit -C "$d" add long.txt; tgit -C "$d" commit -qm changes
printf 'HEAD^' > "$s/rev"
label='explicit revision'; edit
expect_args 'a clean checkout still jumps for diff REV' +17 long.txt
: > "$s/rev"
label='no hunk'; edit
expect_args 'a file with no hunk opens plainly' long.txt

# New files, binary files, deletion-only hunks, and deleted paths.
file=new.txt; printf 'new\n' > "$d/$file"
label=untracked; edit; expect_args 'an untracked new file starts at 1' +1 new.txt
tgit -C "$d" add new.txt
label='staged addition'; edit; expect_args 'a staged new file starts at 1' +1 new.txt
file=binary.dat; printf '\0old\n' > "$d/$file"
tgit -C "$d" add binary.dat; tgit -C "$d" commit -qm binary
printf '\0new\n' > "$d/$file"
label=binary; edit; expect_args 'a binary diff opens plainly' binary.dat
file=long.txt; : > "$d/$file"
label='zero start hunk'; edit; expect_args 'a +0,0 hunk clamps to line 1' +1 long.txt
rm "$d/$file"
label=deleted; edit; expect_args 'a deleted path keeps its plain editor invocation' long.txt

# No HEAD yet takes the staged diff, not a failed HEAD comparison.
mkdir "$box/unborn"
git init -q -b main "$box/unborn"
printf 'first\n' > "$box/unborn/first.txt"
tgit -C "$box/unborn" add first.txt
: > "$PREEN_EDITOR_LOG"
( cd "$box/unborn" && PREEN_STATE="$s" EDITOR="$editor" "$PREEN" --edit first.txt )
expect_args 'an initial staged file starts at 1' +1 first.txt

# PR lookup uses its cached file slice, but opens the local path. Distinct
# neighboring hunks catch accidentally taking the first hunk of the whole PR.
printf 'pr' > "$s/kind"
cat > "$s/pr.diff" <<'DIFF'
diff --git a/other.txt b/other.txt
@@ -3 +3 @@
-old
+new
diff --git a/new.txt b/new.txt
@@ -44,2 +44,2 @@
-old
+new
DIFF
file=new.txt; label='PR cache'; before="$(snapshot "$d")"; edit
expect_args 'PR jumps using the selected cached hunk, opening the local copy' +44 new.txt
assert_eq "$(snapshot "$d")" "$before" 'PR editor dispatch writes nothing to the checkout'

# Worktree comparisons honor their base and raw path even when the open path
# contains spaces, quotes, a newline and literal shell substitutions.
wt="$box/odd dir ' \$(never-run)"$'\nworktree'
git -C "$d" worktree add -q -b editor-test "$wt" HEAD
file=$'odd\nquote"\\.txt'
printf 'first\n' > "$wt/$file"
printf 'diff' > "$s/kind"
printf '%s' "$wt" > "$s/dir"
git -C "$wt" rev-parse HEAD > "$s/rev"
open_path="$wt/$file"; label='worktree odd path'
before="$(snapshot "$wt")"; edit
expect_args 'worktree opens one intact absolute path at line 1' +1 "$open_path"
assert_eq "$(snapshot "$wt")" "$before" 'worktree editor dispatch writes nothing to the checkout'
# Committed worktree edits need the recorded base, even with a clean index.
file=long.txt
sed '40s/.*/worktree committed change/' "$wt/$file" > "$box/edited"
cp "$box/edited" "$wt/$file"
tgit -C "$wt" add long.txt; tgit -C "$wt" commit -qm worktree-change
open_path="$wt/$file"; label='worktree merge-base'; edit
expect_args 'worktree committed changes use the recorded base' +37 "$open_path"

# The actual picker binding must reach --edit while its temporary state lives.
# Simulate only fzf placeholder quoting, leaving preen to choose the callback.
cat > "$box/bin/fzf" <<'FZF'
#!/usr/bin/env python3
import os, shlex, subprocess, sys
raw = sys.stdin.buffer.read()
bind = next(x for x in sys.argv if x.startswith('ctrl-e:execute('))
command = bind[len('ctrl-e:execute('):]
command = command.split(')+reload-sync(', 1)[0] if ')+reload-sync(' in command else command[:-1]
file = os.environ['PREEN_EDIT_TEST_FILE']
if '--review-file' in command:
    record = next(r for r in raw.split(b'\0') if r.split(b'\x1f', 2)[-1] == os.fsencode(file))
    selected = record.split(b'\x1f', 1)[0].decode()
else:
    selected = file
command = command.replace('{}', shlex.quote(file))
command = command.replace('{1}', shlex.quote(selected))
sys.exit(subprocess.call(command, shell=True, executable='/bin/sh'))
FZF
chmod +x "$box/bin/fzf"
printf 'changed locally\n' > "$d/new.txt"
: > "$PREEN_EDITOR_LOG"
( cd "$d" && PATH="$box/bin:$PATH" EDITOR="$box/bin/nvim" PREEN_EDIT_TEST_FILE=new.txt "$PREEN" diff ) </dev/null >/dev/null 2>&1
expect_args 'the live ctrl-e binding dispatches to the line-aware callback' +1 new.txt

# Odd relative filenames must stay one argument and option-like names stay files.
printf 'diff' > "$s/kind"; : > "$s/dir"; : > "$s/rev"; open_path=""
for file in '-dash.txt' '+command.txt' $'quote"slash\\\ttab\nline.txt'; do
  printf 'new\n' > "$d/$file"
  label='odd filename'; edit
  case "$file" in [-+]*) expected="./$file" ;; *) expected="$file" ;; esac
  expect_args 'odd filename remains one literal argument' +1 "$expected"
done
