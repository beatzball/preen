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
marked=
case "$2" in */md-headings.json) marked=1 ;; esac
if [ -n "$marked" ] && [ "${PREEN_T_MODE:-}" = escaped-style ]; then
  grep -F '"h2":{"block_prefix":"\n\n\u001b[9902m","block_suffix":"\u001b[9900m\n"}' "$2" >/dev/null || exit 1
fi
heading() {
  if [ -n "$marked" ]; then printf '\033[990%sm' "$1"; fi
}
end() {
  if [ -n "$marked" ]; then printf '\033[9900m'; fi
  printf '\n'
}
if [ "${PREEN_T_MODE:-}" = no-headings ]; then
  printf 'ordinary text\n'
  exit
fi
cat "$5"
printf 'Same\n  # Same\n\n'
if [ -n "$marked" ] && [ "${PREEN_T_MODE:-}" = mismatch ]; then
  printf 'Unexpected wrap\n'
fi
heading 1; printf 'Same'; end
printf '\n'
if [ "${PREEN_T_MODE:-}" = quoted-blank ]; then printf '  │ '; fi
heading 2
if [ "${PREEN_T_MODE:-}" = leading-blank ]; then printf '   \n'; fi
if [ "${PREEN_T_MODE:-}" = quoted-blank ]; then printf '\n  │ \n  │ '; fi
if [ "$4" = 28 ]; then
  printf 'A long heading\n  over two lines'
else
  printf 'A long heading over two lines'
fi
end
printf '\n'
heading 3
if [ "${PREEN_T_MODE:-}" != empty-heading ]; then printf 'Same'; fi
end
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
grep -qx 'ctrl-g headings' "$box/args"
assert_true "$?" 'heading hint has its own line'
assert_eq "$(cat "$box/inherited-width")" '' 'a width from an outer fzf cannot mask a hidden preview'
export PREEN_STATE="$box/state" FZF_PREVIEW_COLUMNS=28

pick() {
  PREEN_T_CHOICE="$1" FZF_DEFAULT_OPTS='--header-lines=1' FZF_DEFAULT_OPTS_FILE=menu-options \
    "$PREEN" --md-headings "${2-docs/guide.md}"
  "$PREEN" --md-heading-action "${2-docs/guide.md}"
}

assert_contains "$(pick 3)" 'change-preview-window(+9)' 'the second Same heading maps after the wrapped H2'
assert_eq "$(cat "$box/menu")" "$(printf '4\tSame\n6\tA long heading over two lines\n9\tSame')" \
  'menu retains duplicate headings, excludes body and code, and keeps the wrapped label'
assert_contains "$(pick 1)" 'change-preview-window(+4)' 'the first Same heading maps to its own line'
assert_contains "$(FZF_PREVIEW_COLUMNS=74 pick 3)" 'change-preview-window(+8)' 'the wide render lands one line earlier'
assert_contains "$(PREEN_T_MODE=leading-blank pick 2)" 'change-preview-window(+7)' \
  'heading starts on its first line of text when formatting inserts a blank row'
assert_contains "$(PREEN_T_MODE=quoted-blank pick 2)" 'change-preview-window(+8)' \
  'a quote gutter alone does not count as heading text'
assert_contains "$(PREEN_T_MODE=empty-heading pick 3)" 'change-preview-window(+9)' \
  'an empty heading uses the marked start line'
assert_contains "$(cat "$box/menu")" '(empty heading)' 'the empty heading has a menu label'
printf '%s\n' '{"h\u0032":{"block_\u0070refix":"\n\n","block_suffi\u0078":"\n"}}' > "$box/custom.json"
assert_contains "$(PREEN_GLOW_STYLE="$box/custom.json" PREEN_T_MODE=escaped-style pick 2)" \
  'change-preview-window(+6)' 'style instrumentation preserves JSON-escaped member names'
assert_contains "$(PREEN_T_MODE=mismatch pick 2)" 'cannot locate headings' 'a divergent marked render never supplies an offset'
assert_contains "$(PREEN_T_MODE=no-headings pick 2)" 'no headings' 'an ordinary document reports the empty menu'
assert_contains "$(FZF_PREVIEW_COLUMNS= pick 2)" 'show the preview' 'a hidden preview does not guess a width'
assert_eq "$(pick '')" 'change-border-label( preen · md )' 'cancel returns to the main picker'
assert_eq "$(pick '' '')" '' 'shortcut does nothing without a selected file'
assert_contains "$(pick 1 docs/gone.md)" 'cannot locate headings' 'a vanished document produces a status message'
PREEN_T_CHOICE=3 "$PREEN" --md-headings docs/guide.md
assert_contains "$(FZF_PREVIEW_COLUMNS=74 "$PREEN" --md-heading-action docs/guide.md)" \
  'preview resized' 'an offset from a previous width is discarded'
assert_eq "$("$PREEN" --md-heading-action docs/guide.md)" '' 'the jump position is consumed once'

assert_contains "$(pick 3)" 'preview(cat "$PREEN_STATE/md-heading-accepted")' \
  'a successful jump displays the same render it verified'
[ -f "$PREEN_STATE/md-heading-jumped" ]
assert_true "$?" 'a successful jump records the active offset'
assert_eq "$("$PREEN" --md-heading-reset)" 'change-preview-window(+0)+refresh-preview' \
  'after a jump the next visible preview refreshes at the top'
[ ! -e "$PREEN_STATE/md-heading-jumped" ]
assert_true "$?" 'reset consumes the active offset'
assert_eq "$(FZF_PREVIEW_COLUMNS= "$PREEN" --md-heading-reset)" 'change-preview-window(+0,hidden)' \
  'a hidden preview stays hidden when clearing the offset'
PREEN_T_CHOICE=3 "$PREEN" --md-headings docs/guide.md
printf 'Inserted paragraph\n\n' > docs/guide.md
out="$("$PREEN" --md-heading-action docs/guide.md)"
assert_contains "$out" 'preview changed, try again' 'editing the file with the menu open rejects the old offset'
assert_not_contains "$out" 'change-preview-window(+9)' 'a stale jump does not use the old line'
assert_not_contains "$(cat "$PREEN_STATE/md-heading-accepted")" 'Inserted paragraph' \
  'editing the file does not change the previously accepted preview snapshot'
assert_contains "$(pick 3)" 'change-preview-window(+11)' 'reopening the menu uses the edited render'

PREEN_T_CHOICE=3 "$PREEN" --md-headings docs/guide.md
rm docs/guide.md
assert_contains "$("$PREEN" --md-heading-action docs/guide.md)" 'preview changed, try again' \
  'deleting the file with the menu open rejects the jump'
