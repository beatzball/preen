#!/usr/bin/env bash
# The suite must not be able to touch the checkout it is testing.
#
# Everything else in tests/ grades bin/preen. This file grades the harness, for
# one reason: it has twice done real damage, and both times from nothing more
# exotic than a $TMPDIR that no longer existed.
#
#   - `mktemp` fails, so a variable is empty. A trap then runs
#     `rm -rf "$(cd "$empty" && pwd -P)"` — and cd with an empty argument does
#     not fail, it stays put — so the suite deleted its own tests/ directory.
#   - `mktemp` fails inside new_repo, so `git -C "" add -A; git -C "" commit`
#     staged the working directory and committed it to the live branch.
#
# Both are one shape: an unchecked path reaching `rm -rf`, `cd` or `git -C`.
#
# The first version of this file proved almost none of that. It broke $TMPDIR
# from the very first call, so every test file died at lib.sh's own first
# mktemp — the earliest piece of real work any of them does — and no guard after
# that line was ever reached. Reverting the exact line that deleted tests/ left
# the suite green at 193 passed, 0 failed, while a mid-run failure still deleted
# 11 of the checkout's 12 files. It tested one guard and claimed the class.
#
# So there are three parts here, and they hold different things:
#
#   1. the shapes, forbidden at the source. A new unguarded site is a source
#      change, and this is what catches it the moment it is written.
#   2. the guards themselves, called directly. Cheap, and exact about what each
#      one refuses.
#   3. every mktemp site in every file, end to end, with the failure aimed at
#      that one site so the run reaches it. This is the part that was missing.
set -u
. "$(dirname "$0")/lib.sh"

box=""; probe=""
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set, which is
# what was cleaning that up. Leaving it out is how this file leaked a directory
# per run.
cleanup() { rm -rf ${box:+"$box"} ${probe:+"$probe"} "${_preen_dep_shim:-}"; }
trap cleanup EXIT
mktmpd box preen-harness

# ---- 1. the shapes that did the damage, forbidden at the source -------------
#
# Greps, not behaviour, and deliberately so: the three reverts that slipped past
# the first version of this file were all source edits, and each is refused here
# the moment it is written rather than only when some run happens to reach it.
#
# Two files sit outside the rule, and both have to. lib.sh is where the guarded
# helpers live, so it is the one place that may capture mktemp and check it. This
# file is where the rule is written down, so every pattern it forbids appears in
# it verbatim, and grading itself would only ever find itself. Comment-only lines
# are skipped as well, so a comment may still quote the shape it warns about.
under_rule() {
  ( cd "$PREEN_ROOT/tests" && grep -n "$1" *.sh ) 2>/dev/null \
    | grep -v '^lib\.sh:' | grep -v '^test-harness\.sh:' \
    | grep -v ':[0-9]*:[[:space:]]*#' || true
}

offenders="$(under_rule '=[\"]\{0,1\}\$(mktemp')"
assert_eq "$offenders" "" \
  "no test builds a path with a bare mktemp — mktmpd and mktmpf own that, and check it"

ungated="$(under_rule '\$( *new_repo\|\$( *preen_state' | grep -v '|| exit' || true)"
assert_eq "$ungated" "" \
  "every new_repo and preen_state capture carries || exit 1 — they run in a subshell and cannot exit for you"

badcd="$(under_rule 'cd \"\$[A-Za-z_][A-Za-z0-9_]*\" *&& *pwd')"
assert_eq "$badcd" "" \
  "nothing resolves a path with cd \$x && pwd — cd with an empty argument answers for the cwd"

# ---- 2. the guards themselves -----------------------------------------------
#
# Called directly, in a subshell so their exit is observable. A broken TMPDIR is
# a directory that does not exist, which is what makes mktemp fail.
broken="$box/no-such-tmpdir"

( TMPDIR="$broken"; mktmpd x preen-probe ) >/dev/null 2>&1
assert_eq "$?" "1" "mktmpd exits rather than handing back an empty path"
( TMPDIR="$broken"; mktmpf x preen-probe ) >/dev/null 2>&1
assert_eq "$?" "1" "mktmpf exits rather than handing back an empty path"

msg="$( TMPDIR="$broken"; mktmpd x preen-probe 2>&1 )"
assert_contains "$msg" "no temporary" "and says what it could not get"
assert_contains "$msg" "$broken"      "and names the TMPDIR it was given"

# The exact round-2 killer: an empty variable resolved through cd.
( empty=""; resolve_dir empty ) >/dev/null 2>&1
assert_eq "$?" "1" "resolve_dir refuses an empty variable instead of answering with the cwd"
( gone="$broken"; resolve_dir gone ) >/dev/null 2>&1
assert_eq "$?" "1" "and refuses one that is not a directory"

# And it still does its job on a real one.
mktmpd probe preen-probe
before="$probe"; resolve_dir probe
[ -d "$probe" ] && [ "${probe#/}" != "$probe" ]
assert_true $? "and resolves a real directory to an absolute path ($([ "$probe" = "$before" ] && echo unchanged || echo resolved))"

# preen has a temporary directory of its own, and it was unchecked too. With an
# empty $PREEN_STATE every write below it lands at the filesystem root and the
# mode carries on looking like it worked.
#
# With a stand-in fzf, because preen is meant to die long before the picker and
# the day it does not the real one would open a terminal and hang the suite
# rather than fail it. That has happened twice on this branch.
nofzf="$box/nofzf"; mkdir -p "$nofzf"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$nofzf/fzf"
chmod +x "$nofzf/fzf"

prerr="$( cd "$PREEN_ROOT" && TMPDIR="$broken" PATH="$nofzf:$PATH" \
          "$PREEN" diff 2>&1 </dev/null || true )"
assert_contains "$prerr" "no temporary directory" \
  "preen says so too when it cannot make its own state directory"
( cd "$PREEN_ROOT" && TMPDIR="$broken" PATH="$nofzf:$PATH" \
    "$PREEN" diff >/dev/null 2>&1 </dev/null )
assert_eq "$?" "1" "and exits rather than writing its state to the filesystem root"

# ---- 3. every mktemp site, end to end ---------------------------------------
#
# One run per site, with mktemp failing at that site and nowhere else, so the run
# reaches it and aborts there. Then the checkout copy must be untouched.
#
# Keyed on the site NAME, never on a call index. The index moves with the
# environment — a git hook that calls mktemp shifts every number after it — and
# a sweep pinned to indexes would drift from the sites it means to cover. The
# names are literal in the source, so they are read out of it.
#
# The template is built once and copied per job, because a git init plus a
# commit per job is the expensive part, and the jobs run in parallel.

site_names() {
  # site_names <file> -> every temporary-path site in it, by name
  #
  # Two patterns, and the second is not redundant. Reading only the guarded
  # `mktmpd`/`mktmpf` calls means a site that is REVERTED to a raw mktemp
  # disappears from this list — so the sweep would stop testing the one site that
  # had just become dangerous. The raw template is matched as well, which keeps a
  # reverted site under the sweep instead of quietly exempting it.
  {
    grep -oE '\bmktmp[df] +[A-Za-z_][A-Za-z0-9_]* +[A-Za-z0-9._-]+' "$1" \
      | awk '{print $3}'
    grep -oE '/[A-Za-z0-9._-]+\.XXXXXX' "$1" | sed 's|^/||; s|\.XXXXXX$||'
  } 2>/dev/null | LC_ALL=C sort -u
}

shim="$box/shim"; mkdir -p "$shim"
real_mktemp="$(command -v mktemp)"
cat > "$shim/mktemp" <<EOF
#!/bin/sh
case " \$* " in
  *"/\${PREEN_MKTEMP_FAIL_SITE:-__no_such_site__}.XXXXXX"*) exit 1 ;;
esac
exec "$real_mktemp" "\$@"
EOF
chmod +x "$shim/mktemp"

# The pristine template: a git repository, because a stray `git -C ""` has to
# have something to damage and be visible when it does. One commit, and a file
# with an uncommitted edit — work in tests/ is exactly what the rm -rf destroyed.
tmpl="$box/template"
mkdir -p "$tmpl"
( cd "$PREEN_ROOT" && tar -cf - bin tests ) | tar -x -C "$tmpl"
git init -q -b main "$tmpl"
printf 'uncommitted work nobody wants deleted\n' > "$tmpl/tests/scratch.txt"
tgit -C "$tmpl" add -A
tgit -C "$tmpl" commit -qm baseline
printf 'edited after the commit\n' >> "$tmpl/tests/scratch.txt"

manifest() {
  # manifest <dir> -> every file and its bytes, .git included
  #
  # .git is in, so a commit or a staged change counts as damage too: that is the
  # second thing this suite has done to a checkout, and it leaves no trace in
  # the working tree at all.
  ( cd "$1" && find . -type f -not -path './tmp/*' | LC_ALL=C sort \
      | xargs shasum 2>/dev/null )
}
tmpl_manifest="$(manifest "$tmpl")"

jobs="$box/jobs"; : > "$jobs"
for t in "$PREEN_ROOT"/tests/test-*.sh; do
  b="${t##*/}"
  # test-harness.sh is this file. Running it here would recurse.
  case "$b" in test-harness.sh) continue ;; esac
  for nm in $(site_names "$t"); do printf '%s %s\n' "$b" "$nm" >> "$jobs"; done
done
# lib.sh's sites are shared by every file, so they are swept once, through a
# file that is neither the cheapest nor the slowest.
for nm in $(site_names "$PREEN_ROOT/tests/lib.sh"); do
  printf 'test-diff-list.sh %s\n' "$nm" >> "$jobs"
done

njobs="$(grep -c . "$jobs" || true)"
# Not decoration: with the glob unmatched or site_names silent this sweep would
# run nothing, and the assertion below would pass on an untouched template.
[ "${njobs:-0}" -ge 25 ]
assert_true $? "the sweep found sites to fail ($njobs of them, across every test file)"

run_job() {
  # run_job <file> <site> <slot> -> writes a verdict line to $box/out.<slot>
  local f="$1" site="$2" slot="$3" work="$box/w$slot" out="$box/out.$slot"
  rm -rf "$work"; cp -R "$tmpl" "$work"
  # A TMPDIR that WORKS. The point is that mktemp fails at one site and nowhere
  # else, so the run gets that far. Breaking TMPDIR outright is what the first
  # version of this file did, and it never reached past lib.sh's own first call.
  mkdir -p "$work/tmp"
  ( cd "$work/tests" \
      && TMPDIR="$work/tmp" PREEN_MKTEMP_FAIL_SITE="$site" \
         PATH="$shim:$PATH" bash "$f" </dev/null >/dev/null 2>&1 )
  if [ "$(manifest "$work")" = "$tmpl_manifest" ]; then
    printf 'ok %s %s\n' "$f" "$site" > "$out"
  else
    printf 'DAMAGED %s %s\n' "$f" "$site" > "$out"
  fi
  rm -rf "$work"
}

# Batched rather than one at a time: the sweep is the slow half of this file, and
# every job is independent. bash 3.2 has no `wait -n`, so a full batch is waited
# on before the next starts.
width="${PREEN_HARNESS_JOBS:-4}"
damaged=""; done_n=0
slot=0
while IFS=' ' read -r f site; do
  [ -n "$f" ] || continue
  run_job "$f" "$site" "$slot" &
  slot=$((slot + 1))
  if [ "$slot" -ge "$width" ]; then
    wait
    i=0; while [ "$i" -lt "$slot" ]; do
      v="$(cat "$box/out.$i" 2>/dev/null || echo "MISSING $i")"
      case "$v" in DAMAGED*|MISSING*) damaged="$damaged
$v" ;; esac
      done_n=$((done_n + 1)); i=$((i + 1))
    done
    slot=0
  fi
done < "$jobs"
if [ "$slot" -gt 0 ]; then
  wait
  i=0; while [ "$i" -lt "$slot" ]; do
    v="$(cat "$box/out.$i" 2>/dev/null || echo "MISSING $i")"
    case "$v" in DAMAGED*|MISSING*) damaged="$damaged
$v" ;; esac
    done_n=$((done_n + 1)); i=$((i + 1))
  done
fi

assert_eq "$done_n" "$njobs" "every job in the sweep reported back"
assert_eq "$damaged" "" \
  "no mktemp failure point in any test file damages the checkout it runs from"

# ---- and the failure is loud, not merely harmless ---------------------------
# A suite that quietly does nothing is how a broken TMPDIR goes unnoticed until
# the day it is destructive.
( cd "$tmpl/tests" && TMPDIR="$broken" bash test-worktrees.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "a test file given a broken TMPDIR exits non-zero rather than carrying on"
( cd "$tmpl" && TMPDIR="$broken" tests/run.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "run.sh fails the whole run when TMPDIR is unusable"
