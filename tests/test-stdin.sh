#!/usr/bin/env bash
# Piped input: which renderer preen picks, and what it does with the result.
#
# The sniff is the whole of this path. Getting it wrong sends markdown to delta
# or a diff to glow, and neither fails loudly — you just get mangled output.
set -u
. "$(dirname "$0")/lib.sh"

# Which renderer ran, without depending on what either one prints. Shims log
# their own name and swallow the input; whichever file appears is the answer.
rendered_by() {
  # rendered_by <<< input   -> "delta", "glow", or "" if neither ran
  local shim mark
  shim="$(mktemp -d "${TMPDIR:-/tmp}/preen-r.XXXXXX")"
  mark="$shim/who"
  for t in delta glow; do
    cat > "$shim/$t" <<EOF
#!/bin/sh
printf '%s' "$t" > "$mark"
cat > /dev/null
EOF
    chmod +x "$shim/$t"
  done
  # glow's version gate runs before the sniff, so the shim has to satisfy it.
  cat > "$shim/glow" <<EOF
#!/bin/sh
case "\$1" in --version) printf 'glow version 3.0.0\n'; exit 0 ;; esac
printf 'glow' > "$mark"
cat > /dev/null
EOF
  chmod +x "$shim/glow"
  PATH="$shim:$PATH" "$PREEN" - > /dev/null 2>&1
  cat "$mark" 2>/dev/null
  rm -rf "$shim"
}

# ---- the three diff signatures ----------------------------------------------
got="$(printf 'diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n' | rendered_by)"
assert_eq "$got" "delta" "a diff --git header goes to delta"

got="$(printf '@@ -1,2 +1,2 @@\n-old\n+new\n' | rendered_by)"
assert_eq "$got" "delta" "a bare @@ hunk header goes to delta"

got="$(printf -- '--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n' | rendered_by)"
assert_eq "$got" "delta" "a --- and +++ pair goes to delta"

# ---- and the one that must NOT be read as a diff ----------------------------
# Markdown uses --- for a horizontal rule and for frontmatter. On its own it
# must not count, or half of anyone's notes would go to delta.
got="$(printf 'Some notes\n\n---\n\nMore notes\n' | rendered_by)"
assert_eq "$got" "glow" "a lone --- rule stays markdown"

got="$(printf -- '---\ntitle: A page\n---\n\nBody\n' | rendered_by)"
assert_eq "$got" "glow" "frontmatter stays markdown"

got="$(printf '# Heading\n\nA paragraph.\n' | rendered_by)"
assert_eq "$got" "glow" "ordinary markdown goes to glow"

# ---- a coloured diff ---------------------------------------------------------
# git diff --color=always paints its own headers, so the sniff strips ANSI
# first. Without that step ^--- never matches and a coloured diff is read as
# markdown — the exact case the docs promise works.
d="$(new_repo)"; trap 'rm -rf "$d" "${_preen_dep_shim:-}"' EXIT
printf 'changed\n' >> "$d/f.txt"
got="$(git -C "$d" diff --color=always | rendered_by)"
assert_eq "$got" "delta" "a --color=always diff is still read as a diff"

# ---- empty input -------------------------------------------------------------
out="$(printf '' | "$PREEN" - 2>&1 || true)"
assert_contains "$out" "nothing on stdin" "empty input is refused by name"

# ---- colour survives into a pipe --------------------------------------------
# The promise is that redirecting to a file keeps the escapes, so `less -R`
# later looks the same as it did live.
out="$(git -C "$d" diff | "$PREEN" - 2>/dev/null | cat -v | head -40)"
assert_contains "$out" "^[[" "escapes survive when stdout is a pipe"
