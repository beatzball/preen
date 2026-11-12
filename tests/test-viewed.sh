#!/usr/bin/env bash
# Drive the real picker bindings and callbacks with an fzf stand-in. All state
# and repositories are disposable, including under the harness failure sweep.
set -u
. "$(dirname "$0")/lib.sh"

mktmpd box preen-viewed
mktmpd shim preen-viewed-shim
d="$(new_repo)" || exit 1
other="$(new_repo)" || exit 1
trap 'rm -rf "$box" "$shim" "$d" "$other" "${_preen_dep_shim:-}"' EXIT
export XDG_STATE_HOME="$box/state" PREEN_T_CAPTURE="$box/capture"
export PREEN_T_FILE=f.txt PREEN_T_ACTION=none
export PREEN_T_PR_DIFF="$box/pr.diff" PREEN_T_PR_NAMES="$box/pr.names"

cat > "$shim/fzf" <<'PY'
#!/usr/bin/env python3
import os, pathlib, shlex, subprocess, sys
state = pathlib.Path(os.environ["PREEN_STATE"])
out = pathlib.Path(os.environ["PREEN_T_CAPTURE"])
raw = sys.stdin.buffer.read()
# Accept the worktree on level one, then leave level one after its file picker.
if (state / "kind").read_text().strip() == "wt":
    if (out / "entered").exists():
        sys.exit(0)
    (out / "entered").touch()
    sys.stdout.buffer.write(raw.split(b"\0")[0] + b"\n")
    sys.exit(0)
(out / "initial").write_bytes(raw)
(out / "argv").write_text("\n".join(sys.argv[1:]))
args = sys.argv[1:]
header = args[args.index("--header") + 1]
(out / "header").write_text(header)
store = state / "review-dir"
(out / "store").write_text(store.read_text() if store.exists() else "")
if os.environ["PREEN_T_ACTION"] == "toggle":
    bind = next((a for a in args if a.startswith("ctrl-v:")), "")
    # Run precisely the command preen handed fzf, substituting its raw path
    # placeholder as fzf would. A missing binding must fail on the old code.
    if not bind.startswith("ctrl-v:reload-sync("):
        (out / "rc").write_text("missing ctrl-v")
        sys.exit(0)
    command = bind[len("ctrl-v:reload-sync("):-1]
    selected = next(r for r in raw.split(b"\0") if r.split(b"\x1f", 2)[-1] == os.fsencode(os.environ["PREEN_T_FILE"]))
    command = command.replace("{1}", shlex.quote(selected.split(b"\x1f", 1)[0].decode()))
    result = subprocess.run(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out / "after").write_bytes(result.stdout)
    (out / "error").write_bytes(result.stderr)
    (out / "rc").write_text(str(result.returncode))
    load = next(a for a in args if a.startswith("load:transform-header("))
    result = subprocess.run(load[len("load:transform-header("):-1], shell=True, stdout=subprocess.PIPE)
    (out / "after-header").write_bytes(result.stdout)
sys.exit(0)
PY
cat > "$shim/gh" <<'EOF_GH'
#!/bin/sh
case "$1 $2" in
  'auth status') exit 0 ;;
  'pr view') printf '%s\tReview\n' "$3" ;;
  'pr diff')
    case "${4:-}" in --name-only) cat "$PREEN_T_PR_NAMES" ;; *) cat "$PREEN_T_PR_DIFF" ;; esac ;;
  *) exit 1 ;;
esac
EOF_GH
chmod +x "$shim/fzf" "$shim/gh"

view_run() {
  # view_run cwd action args...: logs survive the application's temp cleanup.
  local cwd="$1"; export PREEN_T_ACTION="$2"; shift 2
  rm -rf "$PREEN_T_CAPTURE"; mkdir "$PREEN_T_CAPTURE"
  ( cd "$cwd" && PATH="$shim:$PATH" "$PREEN" "$@" > "$box/stdout" 2> "$box/stderr" )
  printf '%s' "$?" > "$box/rc"
}
view_marked() {
  python3 - "$PREEN_T_CAPTURE/$1" "$PREEN_T_FILE" <<'PY'
import os, sys
raw = open(sys.argv[1], "rb").read().split(b"\0")
path = os.fsencode(sys.argv[2])
sys.exit(0 if any(len(f := r.split(b"\x1f", 2)) == 3 and f[2] == path and "✓".encode() in f[1] for r in raw) else 1)
PY
}

printf 'changed\n' >> "$d/f.txt"
before="$(snapshot "$d")"
view_run "$d" none diff
assert_contains "$(cat "$PREEN_T_CAPTURE/header")" '0 of 1 viewed' 'new target starts with no viewed marks'
assert_true "$([ ! -d "$XDG_STATE_HOME" ]; echo $?)" 'browsing creates no persistent state'
view_run "$d" toggle diff
assert_eq "$(cat "$PREEN_T_CAPTURE/rc")" 0 'ctrl-v callback succeeds'
view_marked after; assert_true $? 'ctrl-v adds a checkmark to the selected file'
assert_contains "$(cat "$PREEN_T_CAPTURE/after-header")" '1 of 1 viewed' 'toggle refreshes the viewed count'
store="$(cat "$PREEN_T_CAPTURE/store")"
[ -s "$store/target" ]; assert_true $? 'target identity is stored alongside marks'
assert_eq "$(find "$store/files" -name '*.viewed' | wc -l | tr -d ' ')" 1 'one small viewed file is persisted'
view_run "$d" none diff
view_marked initial; assert_true $? 'viewed mark survives restarting preen'
mkdir "$d/sub"
view_run "$d/sub" none diff
view_marked initial; assert_true $? 'same target from a subdirectory shares marks'
view_run "$d" toggle diff
view_marked after; assert_eq $? 1 'pressing ctrl-v again unmarks'
assert_contains "$(cat "$PREEN_T_CAPTURE/after-header")" '0 of 1 viewed' 'unmark refreshes the count'
view_run "$d" toggle diff
printf 'new content\n' >> "$d/f.txt"
view_run "$d" none diff
view_marked initial; assert_eq $? 1 'changed content clears the mark'
assert_eq "$(find "$store/files" -name '*.viewed' | wc -l | tr -d ' ')" 0 'stale mark is removed from storage'
# Return to reviewed bytes: a cleared mark must not resurrect.
sed '$d' "$d/f.txt" > "$box/back"; cp "$box/back" "$d/f.txt"
view_run "$d" none diff
view_marked initial; assert_eq $? 1 'returning to old bytes does not restore a cleared mark'
view_run "$d" toggle diff
view_run "$d" none diff HEAD
view_marked initial; assert_eq $? 1 'explicit revision has its own review target'
view_run "$d" toggle diff HEAD
view_run "$d" none diff HEAD
view_marked initial; assert_true $? 'revision marks survive restart'
printf 'changed\n' >> "$other/f.txt"
view_run "$other" none diff
view_marked initial; assert_eq $? 1 'another repository has its own target'
assert_eq "$(snapshot "$d")" "$before" 'viewed operations write nothing to the checkout'

# Binary and untracked files must be keyed by their content too.
printf '\0old' > "$d/binary"
tgit -C "$d" add binary; tgit -C "$d" commit -qm binary
printf '\0new' > "$d/binary"
export PREEN_T_FILE=binary
view_run "$d" toggle diff
view_marked after; assert_true $? 'binary diff can be marked'
printf '\0different' > "$d/binary"
view_run "$d" none diff
view_marked initial; assert_eq $? 1 'binary content changes clear the mark'
export PREEN_T_FILE=$' leading\tquote"back\\line\ntrailing '
printf 'first\n' > "$d/$PREEN_T_FILE"
view_run "$d" toggle diff
view_marked after; assert_true $? 'spaces, tab, quote, backslash and newline survive marking'
view_run "$d" none diff
view_marked initial; assert_true $? 'unusual filename survives restart'
assert_contains "$(cat "$PREEN_T_CAPTURE/argv")" '--review-file show {1}' 'show resolves the original filename through its safe ID'
printf 'second\n' >> "$d/$PREEN_T_FILE"
view_run "$d" none diff
view_marked initial; assert_eq $? 1 'untracked content changes clear the mark'

# PR cache is the source of truth even if the local file differs completely.
export PREEN_T_FILE=f.txt
cat > "$PREEN_T_PR_DIFF" <<'DIFF'
diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1 +1 @@
-old
+reviewed
DIFF
printf 'f.txt\n' > "$PREEN_T_PR_NAMES"
before="$(snapshot "$d")"
view_run "$d" toggle pr 42
view_marked after; assert_true $? 'PR file can be marked from its cached diff'
view_run "$d" none pr 42
view_marked initial; assert_true $? 'PR mark survives restart'
view_run "$d" none pr 43
view_marked initial; assert_eq $? 1 'different PR number has its own target'
printf '+updated\n' >> "$PREEN_T_PR_DIFF"
view_run "$d" none pr 42
view_marked initial; assert_eq $? 1 'updated PR diff clears its mark'
assert_eq "$(snapshot "$d")" "$before" 'PR marking writes nothing to the checkout'

# Worktree review is separate from local diff in that same worktree.
tgit -C "$d" worktree add -qb feature "$box/wt" HEAD
printf 'worktree change\n' >> "$box/wt/f.txt"
before="$(snapshot "$box/wt")"
view_run "$d" toggle wt
view_marked after; assert_true $? 'worktree file can be marked'
view_run "$d" none wt
view_marked initial; assert_true $? 'worktree mark survives restart'
view_run "$box/wt" none diff
view_marked initial; assert_eq $? 1 'worktree review and local diff targets are separate'
printf 'more\n' >> "$box/wt/f.txt"
view_run "$d" none wt
view_marked initial; assert_eq $? 1 'worktree content changes clear the mark'
sed '$d' "$box/wt/f.txt" > "$box/back"; cp "$box/back" "$box/wt/f.txt"
assert_eq "$(snapshot "$box/wt")" "$before" 'worktree marking writes nothing inside that worktree'

# A fully restored worktree must invalidate saved progress on its empty view.
view_run "$d" toggle wt
tgit -C "$box/wt" checkout -- f.txt
view_run "$d" none wt
printf 'worktree change\n' >> "$box/wt/f.txt"
view_run "$d" none wt
view_marked initial; assert_eq $? 1 'empty worktree refresh clears old marks before changes return'

# md stays outside the feature, and a misconfigured state home must not write
# durable review data in a checkout.
printf '# doc\n' > "$d/doc.md"
view_run "$d" none md
assert_not_contains "$(cat "$PREEN_T_CAPTURE/argv")" 'ctrl-v:' 'markdown does not bind the viewed key'
export XDG_STATE_HOME="$d/review-state"
view_run "$d" toggle diff
assert_eq "$(cat "$PREEN_T_CAPTURE/rc")" 1 'state home inside checkout is refused'
[ ! -e "$XDG_STATE_HOME" ]; assert_true $? 'refused state home creates no checkout files'
assert_contains "$(cat "$PREEN_T_CAPTURE/error")" 'outside the checkout' 'invalid state location explains the remedy'

# A missing component before .. must not hide the eventual checkout destination.
export XDG_STATE_HOME="$box/missing/../$(basename "$d")/state"
# The fixture repository is a sibling of box, so place a directory symlink at
# that name to reach it after traversing the missing component and its parent.
ln -s "$d" "$box/$(basename "$d")"
view_run "$d" toggle diff
assert_eq "$(cat "$PREEN_T_CAPTURE/rc")" 1 'missing/../checkout state destination is refused'
[ ! -e "$d/state" ]; assert_true $? 'missing/../checkout creates no review state in the checkout'
export XDG_STATE_HOME="$box/dangling"
ln -s "$d/missing-state" "$XDG_STATE_HOME"
view_run "$d" toggle diff
assert_eq "$(cat "$PREEN_T_CAPTURE/rc")" 1 'dangling symlink into checkout is refused'
[ ! -e "$d/missing-state" ]; assert_true $? 'dangling symlink creates no review state in checkout'

# Staged deletion must hash removed content, including a changed comparison
# base while the index and working tree continue to contain the deletion.
export XDG_STATE_HOME="$box/deletion-state" PREEN_T_FILE=f.txt
tgit -C "$other" rm -qf f.txt
view_run "$other" toggle diff
view_marked after; assert_true $? 'staged deletion can be marked'
# Build a different baseline with the real git entry points, then move HEAD
# without touching the deletion in the index or working tree.
tgit clone -q "$other" "$box/baseline"
printf 'different removed content\n' > "$box/baseline/f.txt"
tgit -C "$box/baseline" add f.txt; tgit -C "$box/baseline" commit -qm baseline
tgit -C "$other" fetch -q "$box/baseline" main
tgit -C "$other" update-ref HEAD "$(git -C "$other" rev-parse FETCH_HEAD)"
view_run "$other" none diff
view_marked initial; assert_eq $? 1 'changed removed content clears staged deletion mark'

# Keep another changed file visible while a marked path temporarily leaves the
# list, proving invalidation visits saved marks rather than current rows only.
tgit -C "$other" reset -q --hard HEAD
printf 'other change\n' > "$other/other.txt"
printf 'review once\n' >> "$other/f.txt"
view_run "$other" toggle diff
tgit -C "$other" checkout -- f.txt
view_run "$other" none diff
printf 'review once\n' >> "$other/f.txt"
view_run "$other" none diff
view_marked initial; assert_eq $? 1 'mark for a path absent at refresh cannot resurrect'

# The empty-list exit also invalidates progress before saying nothing changed.
tgit -C "$other" reset -q --hard HEAD
rm -f "$other/other.txt"
printf 'review again\n' >> "$other/f.txt"
view_run "$other" toggle diff
tgit -C "$other" checkout -- f.txt
view_run "$other" none diff
assert_contains "$(cat "$box/stderr")" 'nothing to show' 'fully restored review has an empty file list'
printf 'review again\n' >> "$other/f.txt"
view_run "$other" none diff
view_marked initial; assert_eq $? 1 'empty-list refresh clears marks before a diff returns'

# On case-insensitive filesystems the same checkout may have another spelling.
case_alias="$(dirname "$d")/$(basename "$d" | tr '[:lower:]' '[:upper:]')"
if [ "$case_alias" -ef "$d" ]; then
  export XDG_STATE_HOME="$case_alias/case-state"
  view_run "$d" toggle diff
  assert_eq "$(cat "$PREEN_T_CAPTURE/rc")" 1 'case alias into checkout is refused by directory identity'
  [ ! -e "$d/case-state" ]; assert_true $? 'case alias creates no review state in checkout'
fi

export XDG_STATE_HOME="$box/safe-again" PREEN_T_FILE=$'has\037sep.txt'
printf 'separator bytes\n' > "$d/$PREEN_T_FILE"
view_run "$d" toggle diff
view_marked after; assert_true $? 'US separator in filename survives ID transport'
view_run "$d" none diff
view_marked initial; assert_true $? 'US filename mark survives restarting'

# Real fzf exercises transformation, scoring, asynchronous reload completion
# and placeholder expansion; a shim cannot establish these contracts.
tgit -C "$other" reset -q --hard HEAD
rm -f "$other/other.txt"
for name in aaa.txt bbb.txt ccc.txt $'has\037sep.txt'; do
  printf 'original\n' > "$other/$name"
done
tgit -C "$other" add .; tgit -C "$other" commit -qm picker
for name in aaa.txt bbb.txt ccc.txt $'has\037sep.txt'; do
  printf 'changed\n' > "$other/$name"
done
mkdir "$box/real-picker"
python3 "$PREEN_ROOT/tests/viewed-picker.py" "$other" "$box/real-picker"
assert_true $? 'real fzf preserves filtered selection, toggles same file, updates count and opens US filename'
