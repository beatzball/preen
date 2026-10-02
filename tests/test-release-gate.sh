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
#
# A function rather than a loop over the values, because three of them hold a
# space, a CR or a newline, and those do not belong in an assertion's label.
malformed() {
  # malformed <fixture> <label> <VERSION bytes> [version a lenient gate reaches]
  #
  # The changelog gets a section headed with the value itself, so a gate with no
  # format rule still finds one and exits 0 rather than 1 for another reason.
  # The fourth argument adds a second section for the value a gate that stripped
  # whitespace, or read only the first line, would arrive at — so those two
  # mutations exit 0 here as well, and the exit assertion is what catches them.
  project "$1" "$3"$'\n' "# Changelog

## [$3]

- a section for exactly this value
${4:+
## [$4]

- a section for the value a more forgiving gate would reach
}"
  gate check "$1"
  assert_eq "$rc" "1" "check exits 1 for a VERSION that is $2"
  assert_contains "$err" "not N.N.N" "...and says so for a VERSION that is $2"
}
malformed four-parts  "four parts, 1.2.3.4"        "1.2.3.4"
malformed v-prefixed  "v-prefixed, v1.2.3"         "v1.2.3"
malformed two-parts   "two parts, 1.2"             "1.2"
malformed blank-line  "a blank line"               ""

# These three are the whole reason this gate reads VERSION with $(cat) and an
# anchored regex instead of roost's `tr -d "[:space:]"`, which would strip the
# space out of "1.2 .3" and call it 1.2.3. Put roost's line back, or validate
# only the first line, and these are what go red.
malformed inner-space "a space inside it, 1.2 .3"  "1.2 .3"       "1.2.3"
malformed carriage    "CRLF, 1.2.3 and a CR"       $'1.2.3\r'      "1.2.3"
malformed second-line "two lines, 1.2.3 then 4.5.6" $'1.2.3\n4.5.6' "1.2.3"

# The CR case again, for the message rather than the exit. Printed raw, a CR
# moves the cursor to the start of the line, so a CI log reads
# "VERSION is '1.2.3', which is not N.N.N" — which names a valid version.
gate check carriage
assert_contains "$err" '\r' "a CR in VERSION is shown as an escape, not printed raw"

# The brief asks for an empty file. The blank-line call above writes one
# newline; this is a file of no bytes at all.
project empty-file "" "# Changelog

## []

- a section for a version that is not there
"
gate check empty-file
assert_eq "$(wc -c < "$root/empty-file/VERSION" | tr -d ' ')" "0" "the empty-file fixture really is 0 bytes"
assert_eq "$rc" "1" "check exits 1 for a VERSION file of no bytes"
assert_contains "$err" "not N.N.N" "...and says it is not N.N.N"

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

# A date after the version is Keep a Changelog's own form, so it must count as
# the heading — and notes must drop that whole line, not print the date.
project dated $'1.2.3\n' '# Changelog

## [1.2.3] - 2026-09-17

### Added

- the new thing

## [1.2.2] - 2026-09-01

- an older thing
'
gate check dated
assert_eq "$rc" "0" "a dated heading counts as this version's section"
gate notes dated
assert_eq "$out" "### Added

- the new thing" "notes drops a dated heading whole, and still stops at the next one"

# A tab before the date, and trailing spaces after the version: both are the
# same kind of whitespace nobody sees in an editor, and neither hides a section.
project dated-tab $'1.2.3\n' "# Changelog

## [1.2.3]"$'\t'"- 2026-09-17

- written with a tab before the date
"
gate check dated-tab
assert_eq "$rc" "0" "a tab before the date still counts as the heading"

# The other side of that rule: what follows the version has to be whitespace.
# Without this, the whole space-or-tab test can be replaced by "accept anything
# after the ]" and the suite stays green.
project glued $'1.2.3\n' '# Changelog

## [1.2.3]x

- a heading with something stuck to the version
'
gate check glued
assert_eq "$rc" "1" "text stuck straight onto the version is not that heading"
assert_contains "$err" "## [1.2.3]" "...and the refusal names the heading it wanted"

project trailing-space $'1.2.3\n' "# Changelog

## [1.2.3]   

- written with trailing spaces on the heading
"
gate check trailing-space
assert_eq "$rc" "0" "trailing spaces on the heading do not hide the section"
gate notes trailing-space
assert_eq "$out" "- written with trailing spaces on the heading" \
  "...and notes still drops that heading"

# A changelog written on Windows: every line ends CR LF. The CR must not hide
# the heading, and must not travel into the release body either.
project crlf $'1.2.3\n' $'# Changelog\r\n\r\n## [1.2.3]\r\n\r\n- a changelog with CRLF line endings\r\n'
gate check crlf
assert_eq "$rc" "0" "a CRLF changelog's heading is still found"
gate notes crlf
assert_eq "$out" "- a changelog with CRLF line endings" \
  "notes strips the CR, so the release body is not full of them"

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

# ---- this repository, as it stands ------------------------------------------
# The fixtures prove the gate works. This proves this checkout passes it, which
# is what catches a VERSION bumped here without its changelog section.
#
# Guarded on VERSION alone. A checkout with no VERSION predates versioning,
# which is a valid state, so it is skipped with a note rather than a PASS that
# grades nothing. A VERSION with no CHANGELOG.md is not skipped: that is the
# mistake this is for.
if [ -f "$PREEN_ROOT/VERSION" ]; then
  "$GATE" check "$PREEN_ROOT" > "$root/self.out" 2> "$root/self.err"; rc=$?
  assert_eq "$rc" "0" "this repository's own VERSION and CHANGELOG.md agree"
  assert_eq "$(cat "$root/self.err")" "" "...and the gate gives no reason to refuse them"
else
  printf '  NOTE: no VERSION in this checkout, so there is nothing of its own to check\n'
fi

# ---- usage ------------------------------------------------------------------
project usage $'1.2.3\n' "$two_sections"
gate publish usage
assert_eq "$rc" "2" "an unknown subcommand is a usage error, exit 2"

# Not through gate(), which always passes a subcommand and one directory.
"$GATE" > "$root/usage.none" 2>&1; rc=$?
assert_eq "$rc" "2" "no subcommand at all is a usage error, exit 2"
assert_contains "$(cat "$root/usage.none")" "usage:" "...and prints the usage line"

"$GATE" check "$root/usage" extra > "$root/usage.many" 2>&1; rc=$?
assert_eq "$rc" "2" "a third argument is a usage error, exit 2"
