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
  docs/node_modules/hidden.md outside.md
ln -s 01.md docs/alias.md

# The suite does not require Glow. This fixture models the private link style's
# marked OSC 8 destinations and the unmarked OSC 8 sequences elsewhere.
cat > "$box/shim/glow" <<'SH'
#!/bin/sh
[ "$1" != --version ] || { printf 'glow version 3.0.0\n'; exit 0; }
[ "${3:-}" = -w ] && [ "$4" = 0 ] && [ -f "$5" ] || exit 1
[ "$5" != docs/01.md ] || exit 0
printf '\033]8;id=image;image.md\007unmarked\033]8;;\007\n'
for url in '../file%0Aname%23.md?q=1#top' '../file%0Aname%23.md?q=1#top' \
           '../node_modules/hidden.md' '../alias.md' '../../outside.md' \
           '../missing.markdown' 'https://host/page.md' '/absolute.md' \
           '//host/page.md' '#heading' '../plain.txt' '../nul%00.md'; do
  printf '\036\033]8;id=link;%s\007display\033]8;;\007\n' "$url"
done
SH
cat > "$box/shim/fzf" <<'SH'
#!/bin/sh
case " $* " in
  *' --read0 '*)
    cat > "$PREEN_T_BOX/state/decorated"
    printf '%s\n' "$@" > "$PREEN_T_BOX/args"
    ;;
  *)
    cat > "$PREEN_T_BOX/menu"
    grep -Fx -e "$PREEN_T_CHOICE" "$PREEN_T_BOX/menu"
    ;;
esac
SH
chmod +x "$box/shim/glow" "$box/shim/fzf"

"$PREEN" md docs
assert_contains "$(cat "$box/args")" 'ctrl-l:execute' 'Markdown picker opens links'
assert_contains "$(cat "$box/args")" 'load:transform' 'Markdown picker updates position after load'
export PREEN_STATE="$box/state"

pick() {
  PREEN_T_CHOICE="$1" "$PREEN" --md-links "${2-$source_file}"
  "$PREEN" --md-link-action pick
}

out="$(pick '../file%0Aname%23.md?q=1#top')"
assert_contains "$out" 'clear-query+reload-sync' 'following clears the query and reloads the complete list'
assert_eq "$("$PREEN" --md-link-action load)" 'pos(2)' 'encoded URL selects the exact NUL-framed row'
assert_eq "$("$PREEN" --md-link-action load)" '' 'load consumes the stored position'
assert_eq "$(cat "$box/menu")" "$(printf '%s\n' '../file%0Aname%23.md?q=1#top' \
  '../node_modules/hidden.md' '../alias.md' '../../outside.md' '../missing.markdown')" \
  'menu lists unique relative Markdown URLs and skips images, absolute URLs, and other files'

for url in '../node_modules/hidden.md' '../alias.md' '../../outside.md' '../missing.markdown'; do
  assert_contains "$(pick "$url")" 'outside the file list' "reports unlisted target $url"
  assert_eq "$("$PREEN" --md-link-action load)" '' 'unlisted target leaves the cursor alone'
done

assert_eq "$(pick '')" 'change-border-label( preen · md )' 'cancel returns to the main picker'
assert_contains "$(pick '' docs/01.md)" 'no relative Markdown links' 'empty link menu reports its status'
assert_contains "$(pick '' docs/deleted.md)" 'cannot read Markdown links' 'a vanished source reports its status'
assert_eq "$(pick '' '')" '' 'shortcut does nothing without a selected file'
