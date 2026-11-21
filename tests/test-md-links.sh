#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"

mktmpd box preen-md-links
trap 'rm -rf "$box" "${_preen_dep_shim:-}"' EXIT
mkdir -p "$box/shim" "$box/state" "$box/docs/sub" "$box/docs/node_modules"
export PREEN_T_BOX="$box" PATH="$box/shim:$PATH"
cd "$box" || exit 1

source_file=docs/sub/source.md
target=$'docs/file\nname#.md'
touch "$source_file" "$target" docs/01.md docs/zz-file.md \
  'docs/a&b.md' 'docs/a&amp;b.md' docs/node_modules/hidden.md outside.md
ln -s 01.md docs/alias.md

# The suite does not require Glow. This fixture models the private link style's
# marked OSC 8 destinations and the unmarked OSC 8 sequences elsewhere.
cat > "$box/shim/glow" <<'SH'
#!/bin/sh
[ "$1" != --version ] || { printf 'glow version 3.0.0\n'; exit 0; }
if [ "${5:-}" = - ]; then
  IFS= read -r input
  case "$input" in
    'x&#46;&#46;&#47;a&amp;b&#46;mdx') printf 'x../a&b.mdx\n' ;;
    'x&#46;&#46;&#47;a&#38;amp&#59;b&#46;mdx') printf 'x../a&amp;b.mdx\n' ;;
    *) exit 1 ;;
  esac
  exit
fi
[ "${3:-}" = -w ] && [ "$4" = 0 ] && [ -f "$5" ] || exit 1
[ "$5" != docs/01.md ] || exit 0
printf '\033]8;id=image;image.md\007unmarked\033]8;;\007\n'
for url in '../file%0Aname%23.md?q=1#top' '../file%0Aname%23.md?q=1#top' \
           '../node_modules/hidden.md' '../alias.md' '../../outside.md' \
           '../missing.markdown' '../a&amp;b.md' '../a\&amp;b.md' 'https://host/page.md' '/absolute.md' \
           '//host/page.md' '#heading' '../plain.txt' '../nul%00.md'; do
  printf '\036\033]8;id=link;%s\007display\033]8;;\007\n' "$url"
done
SH
cat > "$box/shim/fzf" <<'SH'
#!/bin/sh
[ "$1" != --version ] || { printf '%s\n' "${PREEN_T_FZF_VERSION:-0.45.0}"; exit 0; }
case " $* " in
  ' --accept-nth=.. --filter= '*)
    [ "${PREEN_T_ACCEPT_NTH:-0}" = 1 ] || exit 2
    cat
    ;;
  *' --filter= '*)
    printf '%s\n' "$@" > "$PREEN_T_BOX/filter-args"
    cat
    ;;
  *' --read0 '*)
    cat > "$PREEN_T_BOX/state/decorated"
    printf '%s\n' "$@" > "$PREEN_T_BOX/args"
    ;;
  *)
    [ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}" ] || exit 1
    cat > "$PREEN_T_BOX/menu"
    grep -Fx -e "$PREEN_T_CHOICE" "$PREEN_T_BOX/menu"
    ;;
esac
SH
chmod +x "$box/shim/glow" "$box/shim/fzf"

PREEN_T_FZF_VERSION=0.44.1 "$PREEN" md docs
assert_not_contains "$(cat "$box/args")" 'ctrl-l' 'older fzf keeps the ordinary Markdown picker'
"$PREEN" md docs
assert_contains "$(cat "$box/args")" 'ctrl-l:execute' 'Markdown picker opens links'
assert_contains "$(cat "$box/args")" 'load:transform' 'Markdown picker updates position after load'
export PREEN_STATE="$box/state"

pick() {
  PREEN_T_CHOICE="$1" FZF_DEFAULT_OPTS='--header-lines=1' FZF_DEFAULT_OPTS_FILE=menu-options \
    "$PREEN" --md-links "${2-$source_file}"
  "$PREEN" --md-link-action pick
}

out="$(pick '../file%0Aname%23.md?q=1#top')"
assert_contains "$out" 'clear-query+reload-sync' 'following clears the query and reloads the complete list'
assert_eq "$("$PREEN" --md-link-action load)" 'pos(4)' 'encoded URL selects the exact NUL-framed row'
assert_eq "$("$PREEN" --md-link-action load)" '' 'load consumes the stored position'
assert_not_contains "$(cat "$box/filter-args")" '--accept-nth' 'fzf 0.45 lookup uses supported options'
assert_eq "$(cat "$box/menu")" "$(printf '%s\n' '../file%0Aname%23.md?q=1#top' \
  '../node_modules/hidden.md' '../alias.md' '../../outside.md' '../missing.markdown' '../a&amp;b.md' '../a\&amp;b.md')" \
  'menu lists unique relative Markdown URLs and skips images, absolute URLs, and other files'

out="$(PREEN_T_ACCEPT_NTH=1 pick '../file%0Aname%23.md?q=1#top')"
assert_contains "$(cat "$box/filter-args")" '--accept-nth=..' 'lookup overrides accepted-output projections where supported'
assert_contains "$(cat "$box/filter-args")" $'--delimiter=\037' 'lookup uses the same delimiter as the main picker'
assert_eq "$("$PREEN" --md-link-action load)" 'pos(4)' 'full-row projection keeps the original path'

out="$(pick '../a&amp;b.md')"
assert_contains "$out" 'clear-query+reload-sync' 'a CommonMark entity is decoded before following'
assert_eq "$("$PREEN" --md-link-action load)" 'pos(3)' 'decoded path selects the file with an ampersand'
out="$(pick '../a\&amp;b.md')"
assert_contains "$out" 'clear-query+reload-sync' 'a backslash escape preserves the literal entity'
assert_eq "$("$PREEN" --md-link-action load)" 'pos(2)' 'escaped path selects the file with the literal entity'

for url in '../node_modules/hidden.md' '../alias.md' '../../outside.md' '../missing.markdown'; do
  assert_contains "$(pick "$url")" 'outside the file list' "reports unlisted target $url"
  assert_eq "$("$PREEN" --md-link-action load)" '' 'unlisted target leaves the cursor alone'
done

assert_eq "$(pick '')" 'change-border-label( preen · md )' 'cancel returns to the main picker'
assert_contains "$(pick '' docs/01.md)" 'no relative Markdown links' 'empty link menu reports its status'
assert_contains "$(pick '' docs/deleted.md)" 'cannot read Markdown links' 'a vanished source reports its status'
assert_eq "$(pick '' '')" '' 'shortcut does nothing without a selected file'
