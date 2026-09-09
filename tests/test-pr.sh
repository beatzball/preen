#!/usr/bin/env bash
# pr mode: how many times gh is called, what is cached, and that nothing is
# written to the checkout.
#
# gh is stubbed, so none of this touches the network. The stub logs every
# invocation, which is how the "four calls, not one" number in the docs was
# established — and what will notice if a future change adds a fifth.
set -u
. "$(dirname "$0")/lib.sh"

d="$(new_repo)"; shim=""; s=""
trap 'rm -rf "$d" "$shim" "$s"' EXIT

# A PR touching several files, so a per-file call would show up as a count.
DIFF='diff --git a/one.txt b/one.txt
index 111..222 100644
--- a/one.txt
+++ b/one.txt
@@ -1 +1 @@
-old one
+new one
diff --git a/two.txt b/two.txt
index 333..444 100644
--- a/two.txt
+++ b/two.txt
@@ -1 +1 @@
-old two
+new two
diff --git a/three.txt b/three.txt
index 555..666 100644
--- a/three.txt
+++ b/three.txt
@@ -1 +1 @@
-old three
+new three'

shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-gh.XXXXXX")"
LOG="$shim/calls"
: > "$LOG"
cat > "$shim/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LOG"
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")     printf '42\tAdd a thing\n'; exit 0 ;;
  "pr diff")
    for a in "\$@"; do [ "\$a" = "--name-only" ] && {
      printf 'one.txt\ntwo.txt\nthree.txt\n'; exit 0; }
    done
    cat <<'D'
$DIFF
D
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$shim/gh"

files="$(PATH="$shim:$PATH" preen_list "$d" pr 42)"

# ---- the file list ----------------------------------------------------------
assert_eq "$(printf '%s\n' "$files" | tr '\n' ' ')" "one.txt two.txt three.txt " \
  "pr mode lists the files in the PR"

# ---- how many calls, and which ----------------------------------------------
# The claim in the docs is that the count does not grow with the size of the
# PR. Three files, still four calls.
n="$(grep -c . "$LOG")"
assert_eq "$n" "4" "starting a review costs four gh calls, whatever the file count"

grep -q '^auth status' "$LOG";          assert_true $? "gh auth status is checked first"
grep -q '^pr view'    "$LOG";           assert_true $? "gh pr view resolves the number and title"
grep -qx 'pr diff 42' "$LOG";           assert_true $? "the whole diff is fetched once"
grep -q 'pr diff 42 --name-only' "$LOG"; assert_true $? "the file list is fetched once"

# ---- each preview slices the cache, not the network -------------------------
before="$(grep -c . "$LOG")"
s="$(mktemp -d "${TMPDIR:-/tmp}/preen-state.XXXXXX")"
printf 'pr'  > "$s/kind"
printf 'sbs' > "$s/mode"
printf '%s\n' "$DIFF" > "$s/pr.diff"

for f in one.txt two.txt three.txt; do
  out="$(PREEN_STATE="$s" FZF_PREVIEW_COLUMNS=100 PATH="$shim:$PATH" \
         "$PREEN" --preview "$f" 2>/dev/null | strip_ansi)"
  assert_contains "$out" "$f" "preview slices $f out of the cache"
done

after="$(grep -c . "$LOG")"
assert_eq "$after" "$before" "no gh call is made per preview"

# The slice must be the right file, not just any file.
out="$(PREEN_STATE="$s" FZF_PREVIEW_COLUMNS=100 "$PREEN" --preview two.txt 2>/dev/null | strip_ansi)"
assert_contains     "$out" "new two" "the slice carries that file's content"
assert_not_contains "$out" "new one" "the slice does not leak the previous file"
assert_not_contains "$out" "new three" "the slice does not leak the next file"

# ---- read-only ---------------------------------------------------------------
# The headline promise of this mode.
before_snap="$(snapshot "$d")"
PATH="$shim:$PATH" preen_list "$d" pr 42 >/dev/null
PREEN_STATE="$s" "$PREEN" --preview one.txt >/dev/null 2>&1
after_snap="$(snapshot "$d")"
assert_eq "$after_snap" "$before_snap" "pr mode wrote nothing to the checkout"

# No branch was created or switched.
assert_eq "$(git -C "$d" branch --show-current)" "main" "pr mode did not switch branch"

# ---- the preconditions are named rather than crashed on ---------------------
# Emptying PATH to hide gh would also hide bash, so the precondition is driven
# through the stub instead: a gh that is present but not authenticated.
cat > "$shim/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in "auth status") exit 1 ;; esac
exit 1
EOF
chmod +x "$shim/gh"
out="$(cd "$d" && PATH="$shim:$PATH" "$PREEN" pr 42 2>&1 || true)"
assert_contains "$out" "gh auth login" "an unauthenticated gh is named, with the fix"
