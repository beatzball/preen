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
#
#   ./sync-assets.sh             convert everything
#   ./sync-assets.sh --dry-run   resolve every path, write nothing
#
# The dry run exists for CI. Before it this file had `bash -n` and nothing
# else: no job ran it, and the site build does not call it either, so a tape
# renamed in demo/ or a typo in an output path shipped green. What rots in
# here is the path bookkeeping -- the two lists below, the `.gif` -> `.webp`
# mangle, and public/ still being where the site reads from -- so that is what
# the dry run checks. The encode itself is gif2webp's business, and spending
# ~30s a tape on two runners to re-prove libwebp works buys nothing.
set -euo pipefail

DRY=0
# Rejected rather than ignored: a mistyped flag that silently started a real
# encode would fail much later, on a missing gif2webp, and read as a broken
# runner rather than a broken argument.
case "${1-}" in
  '')        ;;
  --dry-run) DRY=1 ;;
  *) printf 'sync-assets: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"

need() {
  command -v "$1" >/dev/null || {
    printf 'sync-assets: %s is not installed (brew install %s)\n' "$1" "$2" >&2
    exit 1
  }
}
# Not under --dry-run. It writes nothing, so it has no use for the encoders,
# and skipping them is what lets CI run it on a runner with no webp installed.
# install.sh --dry-run skips its own `have` checks for the same reason.
if [ "$DRY" = 0 ]; then
  need gif2webp webp
  need cwebp webp
fi

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

# Every conversion below asks this first, in both modes, so the dry run and
# the real run can never disagree about which file goes where -- a dry run
# that recomputed the paths from a second copy of the lists would pass while
# the real one was broken, which is the failure it exists to catch.
#
# Returns 1 to mean "do not encode", which is only ever the dry run: a missing
# source or a missing destination directory exits outright, in both modes, the
# way the inline `[ -f ... ] ||` guards this replaced already did.
plan() {
  local src="$1" out="$2"
  [ -f "$src" ]        || { printf 'sync-assets: MISSING %s\n' "$src" >&2; exit 1; }
  [ -d "${out%/*}" ]   || { printf 'sync-assets: MISSING directory %s/\n' "${out%/*}" >&2; exit 1; }
  if [ "$DRY" = 1 ]; then
    printf '  would write %-24s from %s\n' "$out" "$src"
    return 1
  fi
  return 0
}

report() {
  local src="$1" out="$2"
  local a b
  a=$(wc -c < "$src"); b=$(wc -c < "$out")
  printf '  %-20s %5d KB -> %5d KB  (%d%%)\n' \
    "$(basename "$out")" $((a / 1024)) $((b / 1024)) $((100 - b * 100 / a))
}

for g in "${GIFS[@]}"; do
  out="public/${g%.gif}.webp"
  if plan "../demo/$g" "$out"; then
    # -mixed picks lossy or lossless per frame; -min_size trades encode time
    # for bytes. Both matter here and the encode only runs when a tape changes.
    gif2webp -mixed -m 6 -min_size "../demo/$g" -o "$out" >/dev/null 2>&1
    report "../demo/$g" "$out"
  fi
done

for p in "${PNGS[@]}"; do
  out="public/${p%.png}.webp"
  if plan "../demo/$p" "$out"; then
    cwebp -q 90 -m 6 "../demo/$p" -o "$out" >/dev/null 2>&1
    report "../demo/$p" "$out"
  fi
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
if plan public/logo.png public/logo.webp; then
  cwebp -lossless -q 100 -m 6 public/logo.png -o public/logo.webp >/dev/null 2>&1
  report public/logo.png public/logo.webp
fi
