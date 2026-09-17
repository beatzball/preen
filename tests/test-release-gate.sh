#!/usr/bin/env bash
# scripts/preen-release-gate: the VERSION and CHANGELOG.md bookkeeping a release
# depends on.
#
# That logic is a script rather than inline steps in .github/workflows/ci.yml for
# one reason: a workflow step cannot be tested, and a gate nobody has watched
# fail is not a gate. So it runs here, against throwaway projects that hold a
# VERSION and a CHANGELOG.md and nothing else — one directory per case, so no
# case can pass on a file another case left behind.
set -u
. "$(dirname "$0")/lib.sh"

GATE="$PREEN_ROOT/scripts/preen-release-gate"

root=""
# "${_preen_dep_shim:-}" because this trap replaces the one lib.sh set, which is
# what was cleaning that up.
trap 'rm -rf ${root:+"$root"} "${_preen_dep_shim:-}"' EXIT
mktmpd root preen-gate

project() {
  # project <name> <VERSION bytes> <CHANGELOG.md bytes> -> a fixture directory
  # Bytes as given, so a case controls its own trailing newline. A lone "-"
  # leaves that file out altogether.
  local d="$root/$1"
  mkdir -p "$d"
  [ "$2" = - ] || printf '%s' "$2" > "$d/VERSION"
  [ "$3" = - ] || printf '%s' "$3" > "$d/CHANGELOG.md"
}

gate() {
  # gate <subcommand> <fixture> -> sets rc, out and err
  # stdout and stderr apart: a reason belongs on stderr, where a CI log shows
  # it, and never in the notes a release would publish.
  "$GATE" "$1" "$root/$2" > "$root/$2.out" 2> "$root/$2.err"; rc=$?
  out="$(cat "$root/$2.out")"; err="$(cat "$root/$2.err")"
}

two_sections='# Changelog

## [1.2.3]

### Added

- the new thing

## [1.2.2]

- an older thing
'

# CI calls it by path, not through bash.
[ -x "$GATE" ]; assert_true $? "the gate is executable"

# ---- version ----------------------------------------------------------------
project version $'1.2.3\n' -
gate version version
assert_eq "$rc" "0" "version exits 0, and needs no CHANGELOG.md to do it"
assert_eq "$out" "1.2.3" "version prints the version"
# The capture above would hide a doubled newline, so count the bytes it wrote.
assert_eq "$(wc -c < "$root/version.out" | tr -d ' ')" "6" \
  "version strips the file's trailing newline and prints one of its own, not two"

project version-bare '1.2.3' -
gate version version-bare
assert_eq "$(wc -c < "$root/version-bare.out" | tr -d ' ')" "6" \
  "a VERSION with no trailing newline prints the same six bytes"

# A version that would make a tag named vv1.2.3 is refused here too, not only
# by check.
project version-bad $'v1.2.3\n' -
gate version version-bad
assert_eq "$rc" "1" "version refuses a VERSION that is not N.N.N"
assert_contains "$err" "not N.N.N" "...and says why"

# ---- check: the happy path --------------------------------------------------
project check-ok $'1.2.3\n' "$two_sections"
gate check check-ok
assert_eq "$rc" "0" "check exits 0 when VERSION and its ## [N.N.N] section agree"
assert_contains "$out" "1.2.3" "...and says which version it matched"
assert_eq "$err" "" "...with nothing on stderr"

# ---- check: every way it must refuse ----------------------------------------
project no-version - "$two_sections"
gate check no-version
assert_eq "$rc" "1" "check exits 1 with no VERSION file"
assert_contains "$err" "no VERSION" "...and says the VERSION file is missing"

project no-changelog $'1.2.3\n' -
gate check no-changelog
assert_eq "$rc" "1" "check exits 1 with no CHANGELOG.md"
assert_contains "$err" "no CHANGELOG.md" "...and says CHANGELOG.md is missing"

# Each malformed value gets a section headed with that exact value, so only the
# format rule can refuse it. Without that, a gate with no format rule at all
# would still exit 1 here, for the missing section, and pass.
n=0
for bad in "1.2.3.4" "v1.2.3" "" "1.2"; do
  n=$((n + 1))
  project "malformed-$n" "$bad"$'\n' "# Changelog

## [$bad]

- a section for exactly this value
"
  gate check "malformed-$n"
  assert_eq "$rc" "1" "check exits 1 for VERSION '$bad'"
  assert_contains "$err" "not N.N.N" "...and says '$bad' is not N.N.N"
done

project no-section $'9.9.9\n' "$two_sections"
gate check no-section
assert_eq "$rc" "1" "check exits 1 for a well-formed version with no section"
assert_contains "$err" "## [9.9.9]" "...and names the heading it looked for"

# "## [0.1.0" is a prefix of "## [0.1.0-rc1]", and a release candidate's
# section is not the release's section.
project prefix $'0.1.0\n' '# Changelog

## [0.1.0-rc1]

- a release candidate, not the release
'
gate check prefix
assert_eq "$rc" "1" "an rc section does not satisfy the release version"

# The heading is matched as a whole line, because notes extracts by whole line:
# a check that found "## [0.1.0]" anywhere in a line would pass here and leave
# notes with no section to publish at tag time.
project not-a-heading $'0.1.0\n' '# Changelog

Each release is a section headed like this:

    ## [0.1.0]

## [0.0.9]

- the one before
'
gate check not-a-heading
assert_eq "$rc" "1" "a line that only contains ## [N.N.N] is not its heading"

# ---- notes ------------------------------------------------------------------
# The only section, and the last thing in the file: nothing after it to stop at.
project notes-last $'1.2.3\n' '# Changelog

## [1.2.3]

- the only section, with no heading after it
'
gate notes notes-last
assert_eq "$rc" "0" "notes exits 0 for the last section in the file"
# Exact, not a search for what must be absent: a gate that printed nothing at
# all would pass every "does not contain".
assert_eq "$out" "- the only section, with no heading after it" \
  "notes prints the section body alone, with the ## [N.N.N] heading dropped"

project notes-stops $'1.2.3\n' "$two_sections"
gate notes notes-stops
# The ### line is in the expected text on purpose: ### is not ## [, and a
# subsection must not end the section it belongs to.
assert_eq "$out" "### Added

- the new thing" "notes stops at the next ## [ rather than running to end of file"

project notes-empty $'2.0.0\n' '# Changelog

## [2.0.0]

## [1.9.9]

- the previous one
'
gate notes notes-empty
assert_eq "$rc" "1" "notes refuses an empty section rather than publish a blank release"
assert_contains "$err" "empty" "...and says the section is empty"

project notes-missing $'9.9.9\n' "$two_sections"
gate notes notes-missing
assert_eq "$rc" "1" "notes exits 1 when the section does not exist"
assert_contains "$err" "## [9.9.9]" "...and names the heading it looked for"

# ---- usage ------------------------------------------------------------------
project usage $'1.2.3\n' "$two_sections"
gate publish usage
assert_eq "$rc" "2" "an unknown subcommand is a usage error, exit 2"
