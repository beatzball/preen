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

# `mktemp` anywhere, not `=$(mktemp`. The narrow form matched one spelling, and
# `x="$( mktemp -d )"` — a space after the paren, no template at all — walked
# straight past it while deleting eleven files. There is no legitimate raw use
# left in the tree, so the word itself is the rule.
offenders="$(under_rule 'mktemp')"
assert_eq "$offenders" "" \
  "no test names mktemp at all — mktmpd and mktmpf own that, and check what it returns"

# Backticks as well as `$(...)`: `x=\`new_repo\`` is a capture too, and it walked
# past a pattern that named only the `$(` form. The trailing comment is cut before
# the `|| exit` test, because `grep -v` on the whole line also accepts
# `x="$(new_repo)"   # || exit 1`, where the guard is only being talked about.
ungated="$(under_rule '\$( *new_repo\|\$( *preen_state\|`new_repo\|`preen_state' \
           | sed 's/[[:space:]]*#.*$//' | grep -v '|| exit' || true)"
assert_eq "$ungated" "" \
  "every new_repo and preen_state capture carries || exit 1 — they run in a subshell and cannot exit for you"

# `&& pwd`, not one quoting style: `cd "${x}" && pwd -P` is the same line with
# braces, and it was invisible to the pattern that named `$x` exactly.
badcd="$(under_rule '&&[[:space:]]*pwd')"
assert_eq "$badcd" "" \
  "nothing resolves a path through cd and pwd — cd with an empty argument answers for the cwd"

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
# One run per job, with mktemp failing at ONE use of one template name and
# nowhere else, so the run reaches that use and aborts there. Then the checkout
# copy must be untouched.
#
# Keyed on the template NAME and the Nth use of it, never on a call index. An
# index moves with the environment — a git hook that calls mktemp shifts every
# number after it — while the names are literal in the source.
#
# WHAT THIS COVERS, exactly, because the last two versions of this file claimed
# more than they ran. By default: the FIRST use of every template name in every
# file. That is about 40 jobs against roughly 210 real mktemp calls, because
# names like `preen-test` and `preen-shim` are used many times over. The deeper
# uses of a shared name are NOT swept by default, and the rule in part 1 is what
# covers them: no raw mktemp may exist outside lib.sh in any spelling, so every
# path in the tree comes from a helper that checks it.
#
# PREEN_HARNESS_DEPTH=full sweeps every use of every name instead, which is the
# exhaustive form. It costs a dry run per file to count the uses, then one job
# per use, and takes several minutes.
#
# Every job also reports whether its failure actually FIRED. Without that, a job
# whose file died earlier — or whose template was renamed — comes back green
# having tested nothing, which is how both earlier versions of this file looked
# healthy while holding almost nothing.
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
  # Comment lines are dropped first. Without that, prose picks up names: a line
  # reading "mktmpd cannot get a directory" contributed a site called `get`, and
  # the sweep spent a full run of every file failing a template nobody asks for.
  {
    grep -v '^[[:space:]]*#' "$1" \
      | grep -oE '\bmktmp[df] +[A-Za-z_][A-Za-z0-9_]* +[A-Za-z0-9._-]+' \
      | awk '{print $3}'
    grep -v '^[[:space:]]*#' "$1" \
      | grep -oE '/[A-Za-z0-9._-]+\.XXXXXX' | sed 's|^/||; s|\.XXXXXX$||'
  } 2>/dev/null | LC_ALL=C sort -u
}

can_reach() {
  # can_reach <file> <lib.sh name> -> 0 if that file can get to that template
  #
  # lib.sh's names belong to helpers, and a file that never calls the helper can
  # never reach its mktemp. Sweeping it anyway costs a complete run of the file
  # and grades nothing — 17 of 73 jobs were that. The verdict still reports
  # NOTREACHED, so if this mapping is ever wrong the job says so rather than
  # passing quietly.
  local f="$PREEN_ROOT/tests/$1" nm="$2"
  case "$nm" in
    preen-dep)    return 0 ;;                       # sourced by every file
    preen-test)   grep -q 'new_repo' "$f" ;;
    preen-state)  grep -q 'preen_state' "$f" ;;
    preen-shim)   grep -q 'preen_list_raw \|preen_list ' "$f" ;;
    preen-shim2)  grep -q 'preen_list_raw2' "$f" ;;
    preen-list)   grep -q 'preen_list ' "$f" ;;
    *)            return 0 ;;
  esac
}

shim="$box/shim"; mkdir -p "$shim"
real_mktemp="$(command -v mktemp)"
# Counts every named template it is asked for, and fails only the Nth use of the
# one it was told to fail. Failing EVERY use of a name — which is what the last
# version did — kills the file at the first one, so every later site sharing that
# name is never reached and reports green.
cat > "$shim/mktemp" <<EOF
#!/bin/sh
name=""
for a in "\$@"; do
  case "\$a" in
    *.XXXXXX) b="\${a##*/}"; name="\${b%.XXXXXX}" ;;
  esac
done
if [ -n "\$name" ] && [ -n "\${PREEN_MKTEMP_COUNTS:-}" ]; then
  c="\$PREEN_MKTEMP_COUNTS/\$name"
  n=\$(cat "\$c" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "\$c"
  if [ "\$name" = "\${PREEN_MKTEMP_FAIL_SITE:-}" ] \
     && [ "\$n" -eq "\${PREEN_MKTEMP_FAIL_NTH:-0}" ]; then
    : > "\${PREEN_MKTEMP_FIRED:-/dev/null}"
    exit 1
  fi
fi
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
  ( cd "$1" && find . -type f | LC_ALL=C sort | xargs shasum 2>/dev/null )
}
tmpl_manifest="$(manifest "$tmpl")"

swept_files() {
  # every test file except this one, which would recurse
  for t in "$PREEN_ROOT"/tests/test-*.sh; do
    b="${t##*/}"
    case "$b" in test-harness.sh) continue ;; esac
    printf '%s\n' "$b"
  done
}

uses_of() {
  # uses_of <file> <name> -> how many times that file really uses that template
  #
  # Only asked for under PREEN_HARNESS_DEPTH=full, because it costs a clean run
  # of the file. The counting shim never fails, so this is a plain run.
  local f="$1" cdir="$box/dry.$1"
  if [ ! -d "$cdir" ]; then
    rm -rf "$box/dry"; mkdir -p "$cdir" "$box/dry/tmp"
    cp -R "$tmpl" "$box/dry/checkout"
    ( cd "$box/dry/checkout/tests" \
        && TMPDIR="$box/dry/tmp" PREEN_MKTEMP_COUNTS="$cdir" \
           PATH="$shim:$PATH" bash "$f" </dev/null >/dev/null 2>&1 )
    rm -rf "$box/dry"
  fi
  cat "$cdir/$2" 2>/dev/null || echo 1
}

jobs="$box/jobs"; : > "$jobs"
depth="${PREEN_HARNESS_DEPTH:-first}"
for b in $(swept_files); do
  for nm in $(site_names "$PREEN_ROOT/tests/$b"); do
    if [ "$depth" = full ]; then
      u="$(uses_of "$b" "$nm")"
      [ "$u" -ge 1 ] 2>/dev/null || u=1
      k=1; while [ "$k" -le "$u" ]; do
        printf '%s %s %s\n' "$b" "$nm" "$k" >> "$jobs"; k=$((k + 1))
      done
    else
      printf '%s %s 1\n' "$b" "$nm" >> "$jobs"
    fi
  done
done
# lib.sh's names belong to every file. They are swept through each file that can
# reach them, not once through one: which of them a file uses, and how deep, is
# the calling file's business.
for b in $(swept_files); do
  for nm in $(site_names "$PREEN_ROOT/tests/lib.sh"); do
    can_reach "$b" "$nm" || continue
    printf '%s %s 1\n' "$b" "$nm" >> "$jobs"
  done
done

njobs="$(grep -c . "$jobs" || true)"
# Not decoration: with the glob unmatched or site_names silent this sweep would
# run nothing, and the assertion below would pass on an untouched template.
[ "${njobs:-0}" -ge 25 ]
assert_true $? "the sweep has jobs to run ($njobs of them, across every test file)"

run_job() {
  # run_job <file> <site> <nth> <slot> -> a verdict line in $box/out.<slot>
  #
  # Every scratch path this needs — the run's TMPDIR, the shim's per-name
  # counters, the marker saying the failure fired — lives OUTSIDE the copy being
  # watched. Inside it they are new files, and the manifest reads new files as
  # damage: the first version of this put them in the copy and reported all 73
  # jobs DAMAGED, which is a false alarm, and a false alarm hides a real one.
  local f="$1" site="$2" nth="$3" slot="$4"
  local pen="$box/s$slot" work="$box/s$slot/checkout" out="$box/out.$slot"
  rm -rf "$pen"; mkdir -p "$pen/tmp" "$pen/counts"
  cp -R "$tmpl" "$work"
  # A TMPDIR that WORKS. The point is that mktemp fails at one use of one name and
  # nowhere else, so the run gets that far. Breaking TMPDIR outright is what the
  # first version of this file did, and it never reached past lib.sh's own first
  # call.
  ( cd "$work/tests" \
      && TMPDIR="$pen/tmp" PREEN_MKTEMP_COUNTS="$pen/counts" \
         PREEN_MKTEMP_FAIL_SITE="$site" PREEN_MKTEMP_FAIL_NTH="$nth" \
         PREEN_MKTEMP_FIRED="$pen/fired" \
         PATH="$shim:$PATH" bash "$f" </dev/null >/dev/null 2>&1 )
  if [ "$(manifest "$work")" != "$tmpl_manifest" ]; then
    printf 'DAMAGED %s %s #%s\n' "$f" "$site" "$nth" > "$out"
  elif [ -f "$pen/fired" ]; then
    printf 'ok %s %s #%s\n' "$f" "$site" "$nth" > "$out"
  else
    # Not damage, and not a pass either: the run never got to that use, so this
    # job graded nothing. Counted and reported rather than called green.
    printf 'NOTREACHED %s %s #%s\n' "$f" "$site" "$nth" > "$out"
  fi
  rm -rf "$pen"
}

# Batched rather than one at a time: the sweep is the slow half of this file, and
# every job is independent. bash 3.2 has no `wait -n`, so a full batch is waited
# on before the next starts.
width="${PREEN_HARNESS_JOBS:-4}"
damaged=""; done_n=0; reached=0; unreached=""
slot=0

collect() {
  # collect <slots-used> -> fold this batch's verdicts into the totals
  local n="$1" i=0 v
  while [ "$i" -lt "$n" ]; do
    v="$(cat "$box/out.$i" 2>/dev/null || echo "MISSING slot $i")"
    case "$v" in
      DAMAGED*|MISSING*) damaged="$damaged
$v" ;;
      NOTREACHED*)       unreached="$unreached
$v" ;;
      *)                 reached=$((reached + 1)) ;;
    esac
    done_n=$((done_n + 1)); i=$((i + 1))
  done
}

while IFS=' ' read -r f site nth; do
  [ -n "$f" ] || continue
  run_job "$f" "$site" "${nth:-1}" "$slot" &
  slot=$((slot + 1))
  if [ "$slot" -ge "$width" ]; then wait; collect "$slot"; slot=0; fi
done < "$jobs"
[ "$slot" -gt 0 ] && { wait; collect "$slot"; }

assert_eq "$done_n" "$njobs" "every job in the sweep reported back"
assert_eq "$damaged" "" \
  "no mktemp failure point in any test file damages the checkout it runs from"

# What the sweep actually graded, rather than what it was asked to. A job whose
# failure never fired tested nothing, and the last two versions of this file were
# almost entirely made of those without saying so. The floor catches wholesale
# drift — a template renamed in lib.sh, or a shim that stops matching — which
# would otherwise turn the whole sweep into a long, quiet no-op.
printf '  NOTE: the sweep fired at %s of %s jobs%s\n' "$reached" "$njobs" \
  "$([ -n "$unreached" ] && printf ' (unreached:%s)' "$(printf '%s' "$unreached" | tr '\n' ' ')")"
[ "$reached" -ge 25 ]
assert_true $? "the sweep really failed mktemp at $reached of its $njobs jobs, not merely ran them"

# ---- and the failure is loud, not merely harmless ---------------------------
# A suite that quietly does nothing is how a broken TMPDIR goes unnoticed until
# the day it is destructive.
( cd "$tmpl/tests" && TMPDIR="$broken" bash test-worktrees.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "a test file given a broken TMPDIR exits non-zero rather than carrying on"
( cd "$tmpl" && TMPDIR="$broken" tests/run.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "run.sh fails the whole run when TMPDIR is unusable"
