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
#   3. every path to mktemp in every file, end to end, found by running the
#      file rather than by reading it, with the failure aimed at one call so the
#      run reaches it. Any call that did not come through the helpers fails.
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
# Greps, not behavior, and deliberately so: the three reverts that slipped past
# the first version of this file were all source edits, and each is refused here
# the moment it is written rather than only when some run happens to reach it.
#
# lib.sh is under the rules too. It used to be exempt from all of them, because
# it is where the guarded helpers live — and so it was the one file where a
# nameless `d="$(mktemp -d)"` in new_repo, the exact round-2 bug, passed every
# rule. Now each rule names the helpers that may break it, by function, and only
# inside lib.sh: mktmpd, mktmpf and tmp_refused_for may name mktemp, resolve_dir
# may resolve through cd and pwd. Anything else in lib.sh is graded like a test.
#
# This file is still outside the rules. It is where they are written down, so
# every pattern it forbids appears in it verbatim, and it is not swept either.
#
# Comment-only lines are skipped, so a comment may still quote the shape it warns
# about. The pattern goes through the environment, not awk -v, because -v reads
# backslashes as escapes and would turn `\$\(` into something else.
rule_hits() {
  # rule_hits <ERE> [lib.sh functions allowed] [one whole lib.sh line allowed]
  #   -> file:line:text of every other match
  ( cd "$PREEN_ROOT/tests" \
      && PREEN_RULE="$1" PREEN_RULE_OK=" ${2:-} " PREEN_RULE_LINE="${3:-}" awk '
           FNR == 1 { fn = "" }
           /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ {
             fn = $0; sub(/\(.*/, "", fn); next
           }
           # Anything else that starts a function — a one-liner — or closes
           # one, indented or not, ends the allowed scope. Ending it early only
           # makes the rule stricter.
           /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { fn = "" }
           /^[[:space:]]*}/ { fn = "" }
           /^[[:space:]]*#/ { next }
           $0 ~ ENVIRON["PREEN_RULE"] {
             if (FILENAME == "lib.sh" && fn != "" \
                 && index(ENVIRON["PREEN_RULE_OK"], " " fn " ")) next
             if (FILENAME == "lib.sh" && fn == "" \
                 && ENVIRON["PREEN_RULE_LINE"] != "" \
                 && $0 == ENVIRON["PREEN_RULE_LINE"]) next
             print FILENAME ":" FNR ":" $0
           }' $(ls *.sh | grep -v '^test-harness\.sh$') ) 2>/dev/null || true
}

# `mktemp` anywhere on a line, not `=$(mktemp`, and not even the word alone. The
# narrow form matched one spelling, and `x="$( mktemp -d )"` — a space after the
# paren, no template at all — walked straight past it while deleting eleven
# files. A substring is stricter than a word boundary (it also catches
# `my_mktemp`, a wrapper by another name), and no line in the tree needs either.
offenders="$(rule_hits 'mktemp' 'mktmpd mktmpf tmp_refused_for')"
assert_eq "$offenders" "" \
  "nothing names mktemp outside mktmpd, mktmpf and tmp_refused_for — they check what it returns"

# The rule above lets a whole function through by name, so the names have to mean
# one thing each. A second `mktmpd() {` further down would be a new body under an
# allowed name, and would also be the one bash runs.
for h in mktmpd mktmpf tmp_refused_for resolve_dir; do
  n="$(grep -cE "^[[:space:]]*(function[[:space:]]+$h([[:space:]]|\(|\$)|$h[[:space:]]*\(\))" \
         "$PREEN_ROOT/tests/lib.sh" || true)"
  assert_eq "$n" "1" "lib.sh defines $h exactly once"
done

# The helpers whose every capture must carry `|| exit 1`. Part 3 leans on this
# list too: a key made only of these is failed at its first use, because the
# rule below holds every other caller. One list, so the two cannot drift apart.
guarded="new_repo preen_state"
guarded_re="$(printf '%s' "$guarded" | tr ' ' '|')"

# Backticks as well as `$(...)`: `x=\`new_repo\`` is a capture too, and it walked
# past a pattern that named only the `$(` form. The trailing comment is cut before
# the `|| exit` test, because `grep -v` on the whole line also accepts
# `x="$(new_repo)"   # || exit 1`, where the guard is only being talked about.
ungated="$(rule_hits "\\\$\\( *($guarded_re)|\`($guarded_re)" \
           | sed 's/[[:space:]]*#.*$//' | grep -v '|| exit' || true)"
assert_eq "$ungated" "" \
  "every new_repo and preen_state capture carries || exit 1 — they run in a subshell and cannot exit for you"

# And a name means the same function everywhere. A test that defines its own
# `preview` or `new_repo` runs under lib.sh's name, so a rule or a key that
# trusts the name would be trusting the wrong body.
lib_fns=" $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$PREEN_ROOT/tests/lib.sh" \
            | tr -d '()' | tr '\n' ' ') "
shadows=""
for t in "$PREEN_ROOT"/tests/test-*.sh; do
  # Both forms bash takes: `name()`, and `function name` with or without the
  # parentheses, its brace on the same line or the next.
  # The name has to end where a declaration ends, or `function new_repo-helper`
  # would read as new_repo.
  for fn in $(grep -oE '^[[:space:]]*(function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]|\(|\{|$)|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\))' "$t" \
                | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]({]*\)?$//; s/[[:space:]]*\(\)$//'); do
    case "$lib_fns" in *" $fn "*) shadows="$shadows ${t##*/}:$fn" ;; esac
  done
done
assert_eq "$shadows" "" "no test file redefines a function lib.sh defines"

# `&& pwd`, not one quoting style: `cd "${x}" && pwd -P` is the same line with
# braces, and it was invisible to the pattern that named `$x` exactly. lib.sh's
# own PREEN_ROOT line is the one top-level exception, matched whole: dirname
# never returns an empty string, and that line runs before resolve_dir exists.
badcd="$(rule_hits '&&[[:space:]]*pwd' 'resolve_dir' \
         'PREEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"')"
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

# ---- 3. every call path to mktemp, end to end -------------------------------
#
# One run per job, with mktemp failing at ONE call and nowhere else, so the run
# reaches that call and aborts there. Then the checkout copy must be untouched.
#
# The sweep is built from what the files DO, not from what grep can read in
# them. Each file is first run once with nothing failing, under a stand-in
# mktemp that records every call it gets:
#
#   - a call from mktmpd or mktmpf arrives with its key: the template name and
#     the functions that asked, innermost first (`preen-test+new_repo`). That
#     key, and how many times the file used it, is what the jobs are made of.
#   - a call that arrives WITHOUT a key did not come through the helpers. If it
#     came from a test file rather than from preen or git, it is a raw mktemp,
#     and that fails the run however it was spelled, `mk""temp` and eval
#     included. Only an absolute path such as /usr/bin/mktemp gets round the
#     stand-in, and part 1 refuses the word in any spelling it can read.
#
# The last version enumerated template NAMES by grep. A nameless `mktemp -d` had
# no name, so it had no job; a second helper sharing `preen-test` was never
# reached, because the first use of the name killed the file. Both passed.
#
# Keyed on the call path and the Nth use of it, never on a call index. An index
# moves with the environment — a git hook that calls mktemp shifts every number
# after it — while the keys are names the source spells out.
#
# WHAT THIS COVERS, exactly. By default, a key made only of new_repo and
# preen_state is failed at its FIRST use in each file, and every other key at
# EVERY use — see
# first_use_ok below for why. tests/sweep-sites lists the keys, one file and key per
# line, and the sweep must produce exactly that set: a key that stops existing
# fails the run instead of passing quietly. PREEN_HARNESS_DEPTH=full fails every
# use of every key, lib.sh's helpers included, to the last call.
#
# Every job also reports whether its failure actually FIRED. A job whose file
# died earlier comes back having tested nothing, and that fails the run too.
#
# The template is built once and copied per run, because a git init plus a
# commit per run is the expensive part, and the runs go in parallel.

shim="$box/shim"; mkdir -p "$shim"
real_mktemp="$(command -v mktemp)"
# Counts every keyed call, and fails only the Nth use of the one key it was told
# to fail. An unkeyed call is traced up its parents to see whose it is: preen's
# own calls and git's (a hook can call mktemp) are not this suite's business; any
# other is a raw mktemp, and is written down — "unknown" included, because a
# call nobody can place is not one to wave through.
#
# Two things this does not see, on purpose. A stub script a test writes (a fake
# fzf, say) is "script", like preen: it runs in preen's cwd, a fixture under
# TMPDIR, so an empty path there lands in the fixture, not the checkout — and
# part 1 still reads the heredoc that wrote it. And a call that sets
# PREEN_MKTEMP_VIA itself is taken at its word. That is not a slip anyone makes
# by accident; it is a line a reviewer reads.
#
# owner_of decides by the nearest ancestor that is git, or a shell running a
# script FILE. A test file runs as `bash test-NAME.sh`; preen runs under several
# names and paths (test-version.sh copies it, links it, and puts a space in its
# directory), so any script that is not a test file is "script". Inline code —
# `bash -c`, `-uc`, `-euo pipefail -c`, and `bash -s ARG`, which reads its code
# from stdin and takes ARG as an argument — is not a file, so the search goes
# on to whoever ran it. A process ps cannot read is reported
# as unknown, with the pid: tracing needs ps, and a sandbox that refuses it
# makes every unkeyed call look raw rather than letting them all through.
#
# The comments stay out here because the heredoc below is unquoted, so it can
# put in $real_mktemp: a backtick inside it is a command, even in a comment.
cat > "$shim/mktemp" <<EOF
#!/bin/sh
owner_of() {
  pid=\$1; i=0
  set -f
  while [ "\$i" -lt 12 ] && [ "\${pid:-0}" -gt 1 ]; do
    line="\$(ps -ww -o ppid= -o args= -p "\$pid" 2>/dev/null)" || line=""
    if [ -z "\$line" ]; then
      echo "unknown (ps could not read pid \$pid)"; return
    fi
    set -- \$line
    pid=\$1; shift
    case "\${1##*/}" in
      git) echo git; return ;;
      bash|sh|dash|ksh|zsh)
        shift; inline=""; script=""; skip=""
        for w in "\$@"; do
          if [ -n "\$skip" ]; then skip=""; continue; fi
          case "\$w" in
            --rcfile|--init-file) skip=1 ;;
            --*) ;;
            -*c*|-*s*) inline=1; break ;;
            -*o*|+*o*|-*O*|+*O*) skip=1 ;;
            -*|+*) ;;
            *) script="\$w"; break ;;
          esac
        done
        if [ -z "\$inline" ] && [ -n "\$script" ]; then
          case "\${script##*/}" in
            test-*.sh) echo "\${script##*/}" ;;
            *) echo script ;;
          esac
          return
        fi ;;
    esac
    i=\$((i + 1))
  done
  echo unknown
}
if [ -n "\${PREEN_MKTEMP_VIA:-}" ]; then
  if [ -n "\${PREEN_MKTEMP_COUNTS:-}" ]; then
    c="\$PREEN_MKTEMP_COUNTS/\$PREEN_MKTEMP_VIA"
    n=\$(cat "\$c" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "\$c"
    if [ "\$PREEN_MKTEMP_VIA" = "\${PREEN_MKTEMP_FAIL_SITE:-}" ] \\
       && [ "\$n" -eq "\${PREEN_MKTEMP_FAIL_NTH:-0}" ]; then
      : > "\${PREEN_MKTEMP_FIRED:-/dev/null}"
      exit 1
    fi
  fi
elif [ -n "\${PREEN_MKTEMP_RAW:-}" ]; then
  who="\$(owner_of "\$PPID")"
  case "\$who" in
    script|git) ;;
    *) printf '%s: mktemp %s\n' "\$who" "\$*" >> "\$PREEN_MKTEMP_RAW" ;;
  esac
fi
exec "$real_mktemp" "\$@"
EOF
chmod +x "$shim/mktemp"

# The pristine template: a git repository, because a stray `git -C ""` has to
# have something to damage and be visible when it does. One commit, and a file
# with an uncommitted edit — work in tests/ is exactly what the rm -rf destroyed.
#
# The whole checkout, not only bin/ and tests/. A test may branch on what the
# checkout holds — test-version.sh on VERSION, test-release-gate.sh on scripts/
# — and in a copy without them those branches never ran, so a call inside one
# had no job and nothing said so. Files git ignores (site/node_modules, dist)
# stay out; new files nobody has added yet come in, so a test being written is
# swept before its first commit. Outside a git checkout, everything but .git.
tmpl="$box/template"
mkdir -p "$tmpl"
#
# A file git tracks but you deleted and did not stage is left out rather than
# handed to tar, which would complain about it. Any other failure in the copy
# stops the run: a template missing files is the degraded run this replaced.
if git -C "$PREEN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ( set -o pipefail
    cd "$PREEN_ROOT" || exit 1
    git ls-files -z --cached --others --exclude-standard \
      | while IFS= read -r -d '' p; do
          if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\0' "$p"; fi
        done \
      | tar --null -T - -cf - | tar -x -C "$tmpl" )
else
  ( set -o pipefail
    cd "$PREEN_ROOT" && tar -cf - --exclude ./.git . | tar -x -C "$tmpl" )
fi
if [ "$?" -ne 0 ]; then
  printf '  FAIL: could not copy the checkout into a template under %s\n' "$box"
  exit 1
fi
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

run_job() {
  # run_job <file> <key> <nth> <slot> -> a verdict line in $box/out.<slot>
  #
  # A key of `-` is the clean run: nothing fails, the counts are kept as
  # $box/counts.<file>, and the file has to finish with exit 0 and no FAIL
  # line, or the counts are only the part of it that ran.
  #
  # Every scratch path this needs — the run's TMPDIR, the shim's counters and
  # logs, the marker saying the failure fired — lives OUTSIDE the copy being
  # watched. Inside it they are new files, and the manifest reads new files as
  # damage: the first version of this put them in the copy and reported all 73
  # jobs DAMAGED, which is a false alarm, and a false alarm hides a real one.
  #
  # Only the clean run looks for raw calls. Tracing a call costs a `ps` per
  # parent, preen alone calls mktemp hundreds of times across the jobs, and a
  # job runs nothing the clean run of its file did not already run, up to the
  # one call it fails.
  local f="$1" key="$2" nth="$3" slot="$4"
  local pen="$box/s$slot" work="$box/s$slot/checkout" out="$box/out.$slot" rc nfail raw=""
  rm -rf "$pen"; mkdir -p "$pen/tmp" "$pen/counts"; : > "$pen/raw"
  [ "$key" = - ] && raw="$pen/raw"
  cp -R "$tmpl" "$work"
  # A TMPDIR that WORKS. The point is that mktemp fails at one call and nowhere
  # else, so the run gets that far. Breaking TMPDIR outright is what the first
  # version of this file did, and it never reached past lib.sh's own first call.
  ( cd "$work/tests" \
      && TMPDIR="$pen/tmp" PREEN_MKTEMP_COUNTS="$pen/counts" \
         PREEN_MKTEMP_FAIL_SITE="$key" PREEN_MKTEMP_FAIL_NTH="$nth" \
         PREEN_MKTEMP_FIRED="$pen/fired" PREEN_MKTEMP_RAW="$raw" \
         PATH="$shim:$PATH" bash "$f" </dev/null >"$pen/log" 2>&1 )
  rc=$?
  if [ "$(manifest "$work")" != "$tmpl_manifest" ]; then
    printf 'DAMAGED %s %s #%s\n' "$f" "$key" "$nth" > "$out"
  elif [ -s "$pen/raw" ]; then
    printf 'RAW %s %s #%s: %s\n' "$f" "$key" "$nth" "$(head -1 "$pen/raw")" > "$out"
  elif [ "$key" = - ]; then
    # A clean run has to be a passing run as well as a finished one. A file that
    # cannot do its job in the copy — the release gate with no scripts/, once —
    # exits 0 with dozens of FAIL lines and counts only the calls it got to.
    nfail="$(grep -c '^  FAIL' "$pen/log" || true)"
    if [ "$rc" -eq 0 ] && [ "${nfail:-0}" -eq 0 ]; then
      rm -rf "$box/counts.$f"; mv "$pen/counts" "$box/counts.$f"
      printf 'ok %s clean\n' "$f" > "$out"
    else
      printf 'FAILED %s clean run exited %s with %s FAIL lines\n' \
        "$f" "$rc" "${nfail:-0}" > "$out"
      # Preserve the primary assertion before removing the scratch job.
      sed 's/^/    clean-log: /' "$pen/log" >> "$out"
      if [ -n "${PREEN_TEST_DIAGNOSTICS:-}" ]; then
        mkdir -p "$PREEN_TEST_DIAGNOSTICS"
        cp "$pen/log" "$PREEN_TEST_DIAGNOSTICS/$f.clean.log"
      fi
    fi
  elif [ -f "$pen/fired" ]; then
    printf 'ok %s %s #%s\n' "$f" "$key" "$nth" > "$out"
  else
    # Not damage, but not a pass either: the run never got to that call, so
    # this job graded nothing.
    printf 'NOTREACHED %s %s #%s\n' "$f" "$key" "$nth" > "$out"
  fi
  rm -rf "$pen"
}

# $width runs at a time, and a new one starts the moment any slot is free. bash
# 3.2 has no `wait -n`, so each run leaves a free.<slot> marker when it ends and
# the loop looks for one. Waiting for a whole batch instead left three slots idle
# behind every slow file, and the clean runs are nothing but slow files.
width="${PREEN_HARNESS_JOBS:-4}"

sweep() {
  # sweep <job list> -> runs every "file key nth" line; sets bad, done_n, reached
  local f key nth s slot
  bad=""; done_n=0; reached=0
  s=0; while [ "$s" -lt "$width" ]; do : > "$box/free.$s"; s=$((s + 1)); done
  while IFS=' ' read -r f key nth; do
    [ -n "$f" ] || continue
    slot=""
    while [ -z "$slot" ]; do
      s=0
      while [ "$s" -lt "$width" ]; do
        if [ -f "$box/free.$s" ]; then slot="$s"; break; fi
        s=$((s + 1))
      done
      [ -n "$slot" ] || sleep 0.1
    done
    rm -f "$box/free.$slot"
    collect "$slot"
    { run_job "$f" "$key" "${nth:-1}" "$slot"; : > "$box/free.$slot"; } &
  done < "$1"
  wait
  s=0; while [ "$s" -lt "$width" ]; do collect "$s"; s=$((s + 1)); done
}

collect() {
  # collect <slot> -> fold the verdict that slot left, if any, into the totals
  #
  # A run that died without writing one is not counted, so done_n comes up
  # short and "every job reported back" says so.
  local v
  [ -f "$box/out.$1" ] || return 0
  v="$(cat "$box/out.$1")"; rm -f "$box/out.$1"
  case "$v" in
    ok*) reached=$((reached + 1)) ;;
    *)   bad="$bad
  $v" ;;
  esac
  done_n=$((done_n + 1))
}

# The clean runs, one per file.
clean="$box/clean"; : > "$clean"
for b in $(swept_files); do printf '%s - 0\n' "$b" >> "$clean"; done
nclean="$(grep -c . "$clean" || true)"
sweep "$clean"
assert_eq "$bad" "" \
  "every test file runs clean under the counting mktemp, with no raw mktemp call and no damage"
assert_eq "$reached" "$nclean" "and all $nclean of them finished"

# The jobs, from what the clean runs counted.
jobs="$box/jobs"; : > "$jobs"
#
# Which uses of a key are failed. A key made only of the $guarded helpers —
# `preen-test+new_repo` — runs the same body at every call, and what differs is
# the caller, which part 1 holds: every capture carries `|| exit 1`, and no test
# may redefine the name. So those are failed at their first use. Every other key
# is failed at EVERY use: a test's own helper, any other lib.sh helper, a call at
# a test's top level. Their callers are lines no rule reads, and a second call
# that skips `|| exit 1` was green while the first, guarded one passed for it.
first_use_ok() {
  # first_use_ok <key> -> 0 if every function in the key is in $guarded
  local rest="$1" fn
  case "$rest" in *+*) rest="${rest#*+}" ;; *) return 1 ;; esac
  while [ -n "$rest" ]; do
    fn="${rest%%+*}"
    case " $guarded " in *" $fn "*) ;; *) return 1 ;; esac
    case "$rest" in *+*) rest="${rest#*+}" ;; *) rest="" ;; esac
  done
  return 0
}
depth="${PREEN_HARNESS_DEPTH:-default}"
calls=0
for b in $(swept_files); do
  [ -d "$box/counts.$b" ] || continue
  for c in "$box/counts.$b"/*; do
    [ -f "$c" ] || continue
    key="${c##*/}"; u="$(cat "$c")"; calls=$((calls + u))
    if [ "$depth" = full ] || ! first_use_ok "$key"; then
      k=1; while [ "$k" -le "$u" ]; do
        printf '%s %s %s\n' "$b" "$key" "$k" >> "$jobs"; k=$((k + 1))
      done
    else
      printf '%s %s 1\n' "$b" "$key" >> "$jobs"
    fi
  done
done
njobs="$(grep -c . "$jobs" || true)"

# The pin. Whatever depth, the set of file-and-key pairs must be exactly the one
# written down: a key that disappears — a helper bypassed, a test that stopped
# reaching one — fails here rather than shrinking the sweep without a word. A
# new key fails too, and the fix is to add its line, which puts it in the diff.
{ grep -v '^#' "$PREEN_ROOT/tests/sweep-sites" 2>/dev/null || true; } \
  | grep . | LC_ALL=C sort -u > "$box/pinned"
cut -d' ' -f1,2 "$jobs" | LC_ALL=C sort -u > "$box/swept"
drift="$( LC_ALL=C comm -23 "$box/pinned" "$box/swept" | sed 's/^/  pinned, not swept: /'
          LC_ALL=C comm -13 "$box/pinned" "$box/swept" | sed 's/^/  swept, not pinned: /' )"
npinned="$(grep -c . "$box/pinned" || true)"
assert_eq "$drift" "" "the sweep covers exactly the $npinned keys pinned in tests/sweep-sites"

sweep "$jobs"
printf '  NOTE: %s clean runs made %s helper calls; %s jobs at depth %s, %s of them fired\n' \
  "$nclean" "$calls" "$njobs" "$depth" "$reached"
assert_eq "$done_n" "$njobs" "every job in the sweep reported back"
assert_eq "$bad" "" \
  "every one of the $njobs mktemp failure points fires, and none damages the checkout it runs from"

# ---- and the failure is loud, not merely harmless ---------------------------
# A suite that quietly does nothing is how a broken TMPDIR goes unnoticed until
# the day it is destructive.
( cd "$tmpl/tests" && TMPDIR="$broken" bash test-worktrees.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "a test file given a broken TMPDIR exits non-zero rather than carrying on"
( cd "$tmpl" && TMPDIR="$broken" tests/run.sh </dev/null >/dev/null 2>&1 )
assert_eq "$?" "1" "run.sh fails the whole run when TMPDIR is unusable"
