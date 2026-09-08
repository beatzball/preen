#!/usr/bin/env bash
# Copy the recordings from demo/ into public/, converting them to WebP.
#
# Two things are going on here.
#
# 1. They have to be COPIED rather than referenced. Coolify builds this site
#    with the Base Directory set to /site, so ../demo does not exist inside the
#    Docker build context — anything the pages load must live under public/.
#
# 2. They are CONVERTED because the GIFs are the heaviest thing on the site by
#    a wide margin. preen.gif alone is 531KB, against 65KB for all the HTML,
#    CSS and JavaScript on a doc page put together. As animated WebP the same
#    recording is 193KB and the terminal text stays sharp — `-mixed` lets the
#    encoder pick lossless per frame, which is what keeps it legible.
#
#    demo/ keeps the GIFs. The README renders on GitHub, which wants a GIF,
#    and vhs emits one anyway. Only the site takes the WebP.
#
# Re-run this after `vhs` regenerates any tape in demo/, or the site keeps
# serving the old recording. Nothing fails if you forget.
set -euo pipefail

cd "$(dirname "$0")"

need() {
  command -v "$1" >/dev/null || {
    printf 'sync-assets: %s is not installed (brew install %s)\n' "$1" "$2" >&2
    exit 1
  }
}
need gif2webp webp
need cwebp webp

# vhs writes the GIFs; each becomes an animated WebP of the same name.
GIFS=(
  preen.gif           # docs/getting-started, and the landing page
  preen-pipes.gif     # docs/pipes
  preen-pr.gif        # docs/pull-requests
)

# Stills. -q 90 is visually lossless on a terminal screenshot, which is flat
# colour and text rather than photography.
PNGS=(
  preen-md.png        # docs/getting-started
)

report() {
  local src="$1" out="$2"
  local a b
  a=$(wc -c < "$src"); b=$(wc -c < "$out")
  printf '  %-20s %5d KB -> %5d KB  (%d%%)\n' \
    "$(basename "$out")" $((a / 1024)) $((b / 1024)) $((100 - b * 100 / a))
}

for g in "${GIFS[@]}"; do
  [ -f "../demo/$g" ] || { printf 'sync-assets: MISSING ../demo/%s\n' "$g" >&2; exit 1; }
  out="public/${g%.gif}.webp"
  # -mixed picks lossy or lossless per frame; -min_size trades encode time for
  # bytes. Both matter here and the encode only runs when a tape changes.
  gif2webp -mixed -m 6 -min_size "../demo/$g" -o "$out" >/dev/null 2>&1
  report "../demo/$g" "$out"
done

for p in "${PNGS[@]}"; do
  [ -f "../demo/$p" ] || { printf 'sync-assets: MISSING ../demo/%s\n' "$p" >&2; exit 1; }
  out="public/${p%.png}.webp"
  cwebp -q 90 -m 6 "../demo/$p" -o "$out" >/dev/null 2>&1
  report "../demo/$p" "$out"
done

# The logo, which does not come from demo/ but is derived the same way.
#
# Lossless, and not resized. It is the brand mark, so a lossy pass is not worth
# the 6KB it would save; and resizing it costs bytes rather than saving them —
# the mark is a flat gradient that palettes well, and resampling introduces
# intermediate colours that compress worse than the original.
#
# public/logo.png stays. The favicon pipeline and the OG card both need a PNG,
# and the OG handler inlines it as a data URI at build time, so it is never
# served to a browser. Pages reference logo.webp.
cwebp -lossless -q 100 -m 6 public/logo.png -o public/logo.webp >/dev/null 2>&1
report public/logo.png public/logo.webp
