#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"

mktmpd box preen-md-headings
trap 'rm -rf "$box" "${_preen_dep_shim:-}"' EXIT
mkdir -p "$box/shim" "$box/state" "$box/docs"
export PREEN_T_BOX="$box" PATH="$box/shim:$PATH"
export PREEN_GLOW_STYLE="$box/missing-style.json"
cd "$box" || exit 1
touch docs/guide.md

# Model Glow's output before and after theme instrumentation. The preview
# width changes the second and third heading's offsets. The body and code
# contain the same text as a heading and must never appear in the menu.
cat > "$box/shim/glow" <<'SH'
#!/bin/sh
[ "$1" != --version ] || { printf 'glow version 3.0.0\n'; exit 0; }
[ "$3" = -w ] && [ -f "$5" ] || exit 1
case "$4" in 28|74) ;; *) exit 1 ;; esac
heading() {
  if [ "$2" = dark ]; then
    printf '%s' "$3"
  else
    printf '\033[990%sm%s' "$1" "$3"
  fi
}
end() {
  if [ "$1" = dark ]; then printf '\n'; else printf '\033[9900m\n'; fi
}
if [ "${PREEN_T_MODE:-}" = no-headings ]; then
  printf 'ordinary text\n'
  exit
fi
printf 'Same\n  # Same\n\n'
if [ "$2" != dark ] && [ "${PREEN_T_MODE:-}" = mismatch ]; then
  printf 'Unexpected wrap\n'
fi
heading 1 "$2" 'Same'; end "$2"
printf '\n'
if [ "$4" = 28 ]; then
  heading 2 "$2" 'A long heading'
  printf '\n  over two lines'; end "$2"
else
  heading 2 "$2" 'A long heading over two lines'; end "$2"
fi
printf '\n'
heading 3 "$2" 'Same'; end "$2"
SH
cat > "$box/shim/fzf" <<'SH'
#!/bin/sh
[ "$1" != --version ] || { printf '%s\n' "${PREEN_T_FZF_VERSION:-0.57.0}"; exit 0; }
case " $* " in
  *' --read0 '*)
    cat >/dev/null
    printf '%s\n' "$@" > "$PREEN_T_BOX/args"
    printf '%s' "${FZF_PREVIEW_COLUMNS:-}" > "$PREEN_T_BOX/inherited-width"
    ;;
  *)
    [ -z "${FZF_DEFAULT_OPTS:-}${FZF_DEFAULT_OPTS_FILE:-}" ] || exit 1
    cat > "$PREEN_T_BOX/menu"
    [ -n "${PREEN_T_CHOICE:-}" ] || exit 1
    sed -n "${PREEN_T_CHOICE}p" "$PREEN_T_BOX/menu"
    ;;
esac
SH
chmod +x "$box/shim/glow" "$box/shim/fzf"

PREEN_T_FZF_VERSION=0.56.0 "$PREEN" md docs
assert_contains "$(cat "$box/args")" 'ctrl-l:execute' 'fzf 0.56 can still follow links'
assert_not_contains "$(cat "$box/args")" 'ctrl-g:execute' 'headings need preview dimensions on key actions'
FZF_PREVIEW_COLUMNS=90 "$PREEN" md docs
assert_contains "$(cat "$box/args")" 'ctrl-g:execute' 'Markdown picker opens headings on fzf 0.57'
assert_contains "$(cat "$box/args")" 'focus:transform' 'file changes reset the jump offset'
assert_contains "$(cat "$box/args")" 'resize:transform' 'resizes reset the jump offset'
assert_eq "$(cat "$box/inherited-width")" '' 'a width from an outer fzf cannot mask a hidden preview'
export PREEN_STATE="$box/state" FZF_PREVIEW_COLUMNS=28

pick() {
  PREEN_T_CHOICE="$1" FZF_DEFAULT_OPTS='--header-lines=1' FZF_DEFAULT_OPTS_FILE=menu-options \
    "$PREEN" --md-headings "${2-docs/guide.md}"
  "$PREEN" --md-heading-action
}

assert_contains "$(pick 3)" 'change-preview-window(+9)' 'the second Same heading maps after the wrapped H2'
assert_eq "$(cat "$box/menu")" "$(printf '4\tSame\n6\tA long heading over two lines\n9\tSame')" \
  'menu retains duplicate headings, excludes body and code, and keeps the wrapped label'
assert_contains "$(pick 1)" 'change-preview-window(+4)' 'the first Same heading maps to its own line'
assert_contains "$(FZF_PREVIEW_COLUMNS=74 pick 3)" 'change-preview-window(+8)' 'the wide render lands one line earlier'
assert_contains "$(PREEN_T_MODE=mismatch pick 2)" 'cannot locate headings' 'a divergent marked render never supplies an offset'
assert_contains "$(PREEN_T_MODE=no-headings pick 2)" 'no headings' 'an ordinary document reports the empty menu'
assert_contains "$(FZF_PREVIEW_COLUMNS= pick 2)" 'show the preview' 'a hidden preview does not guess a width'
assert_eq "$(pick '')" 'change-border-label( preen · md )' 'cancel returns to the main picker'
assert_eq "$(pick '' '')" '' 'shortcut does nothing without a selected file'
assert_contains "$(pick 1 docs/gone.md)" 'cannot locate headings' 'a vanished document produces a status message'
PREEN_T_CHOICE=3 "$PREEN" --md-headings docs/guide.md
assert_contains "$(FZF_PREVIEW_COLUMNS=74 "$PREEN" --md-heading-action)" 'preview resized' 'an offset from a previous width is discarded'
assert_eq "$("$PREEN" --md-heading-action)" '' 'the jump position is consumed once'
