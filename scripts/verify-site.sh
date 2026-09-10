#!/bin/sh
# verify-site.sh — probe a preen docs deployment.
#
#   scripts/verify-site.sh http://localhost:8080
#   PREEN_EXPECT_COMMIT=$(git rev-parse HEAD) scripts/verify-site.sh https://preening.dev
#
# Used twice in CI: against the container built from this commit, and against
# production after a deploy. Same checks both times, so "it worked in CI" and
# "it works in production" mean the same thing.
#
# PREEN_EXPECT_COMMIT is the part that matters after a deploy. A Coolify
# webhook only *queues* a build, so probing immediately hits the OLD container
# and passes — a failed deploy then looks green. With it set, the probe retries
# until /version.json reports this exact commit, and fails if it never does.
#
# Env:
#   PREEN_EXPECT_COMMIT   require this commit to be the one being served
#   PREEN_PROBE_RETRIES   attempts (default 10)
#   PREEN_PROBE_DELAY     seconds between attempts (default 3)
set -eu

BASE="${1:?usage: verify-site.sh BASE_URL}"
BASE="${BASE%/}"
retries="${PREEN_PROBE_RETRIES:-10}"
delay="${PREEN_PROBE_DELAY:-3}"
expect="${PREEN_EXPECT_COMMIT:-}"

# Every page the site is supposed to serve. A deploy that drops one of these
# is broken even if the home page loads.
PAGES="/
/docs/getting-started
/docs/browsing
/docs/pipes
/docs/pull-requests
/docs/worktrees
/docs/git-integration
/docs/theming"

# Assets referenced from every page's <head> or body. A deploy that drops one
# breaks the tab icon, a shared link, or the recording, while the pages
# themselves still return 200.
ASSETS="/logo.webp
/preen.webp
/_litro/app.js
/favicon.ico
/favicon-32.png
/apple-touch-icon.png
/__og/index.png
/__og/docs/theming.png"

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  x %s\n' "$*" >&2; fail=1; }

status() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || echo 000; }
body()   { curl -s --max-time 20 "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Wait for the expected commit (or just for the site to answer at all)
# ---------------------------------------------------------------------------
printf 'verify-site: %s\n' "$BASE"
n=0
while :; do
  n=$((n + 1))
  served=$(curl -s --max-time 20 "$BASE/version.json" 2>/dev/null |
             sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$expect" ]; then
    [ "$(status "$BASE/")" = "200" ] && break
  elif [ "$served" = "$expect" ]; then
    note "serving $served"
    break
  fi
  if [ "$n" -ge "$retries" ]; then
    if [ -n "$expect" ]; then
      bad "after $n attempts the site is serving '${served:-<no version.json>}', expected '$expect'"
      bad "the deploy did not land — this is the old container"
    else
      bad "site did not respond after $n attempts"
    fi
    exit 1
  fi
  printf '  waiting (%s/%s) — serving %s\n' "$n" "$retries" "${served:-<nothing>}"
  sleep "$delay"
done

# ---------------------------------------------------------------------------
# 2. Every page, and the assets the pages depend on
# ---------------------------------------------------------------------------
# A `while read` fed by a pipe runs in a subshell, so a `fail=1` set inside it
# is thrown away and a broken page exits 0. A here-doc redirect keeps the loop
# in THIS shell, so the flag survives and no temp file or second grep is needed
# to recover it.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  code=$(status "$BASE$path")
  if [ "$code" = "200" ]; then note "200  $path"; else bad "$code  $path"; fi
done <<EOF
$PAGES
$ASSETS
EOF

# A page that renders nothing still answers 200, so status alone cannot tell a
# working deploy from a broken one -- that is exactly how a client bundle
# importing a Node builtin shipped green once already.
#
# The tokens are RENDERED MARKUP, and that shape is load-bearing twice over.
#
# Not an element name: an empty custom element still puts <page-docs-slug> in
# the document, so that would pass a page that rendered nothing inside it.
#
# And not bare prose either: the same text is carried in the page's JSON data
# island, where quotes come out escaped as id=\"...\". Matching a sentence
# would therefore pass on a document whose island survived but whose markup
# never rendered. `<h2 id="...">` appears only in the real thing -- verified
# against a built page, present in the rendered half and absent from the
# island.
#
# This runs against production too, which the Playwright suite does not: that
# drives `pnpm dev`, a different renderer from the static files nginx serves.
# Tokens are passed as separate arguments, so a token can contain spaces --
# which real prose does, and which is the whole point of using prose.
check_content() {
  path="$1"; shift
  html="$(body "$BASE$path")"
  for token in "$@"; do
    case "$html" in
      *"$token"*) ;;
      *) bad "$path is missing \"$token\" -- the page did not render"; return ;;
    esac
  done
  note "content ok  $path"
}
# Two headings per doc page, from the top and the bottom, so a truncated
# render fails too.
check_content /             '>Built on three great tools<' '>Get Started<'
check_content /docs/theming '<h2 id="one-palette-two-renderers"' '<h2 id="every-environment-variable"' 'class="hljs '
check_content /docs/pipes   '<h2 id="pipe-anything-in"' '<h2 id="where-this-is-already-wired-up-for-you"'

# The "Edit this page" link is assembled from two halves -- a base in
# server/starlight.config.js and a path in pages/docs/[slug].ts -- and both of
# them added `content/docs`, so every doc page linked to
# site/content/docs/content/docs/<slug>.md, which does not exist. The page
# itself still returned 200 and still rendered, so nothing above catches it.
#
# Two assertions, because neither one catches what the other does.
#
# The shape, on every doc page: the doubled segment is in the MIDDLE of the
# URL, so matching the tail (".../pipes.md") passes on the broken link. The
# whole URL is compared instead, which also fails loudly if the base is ever
# changed -- deliberately or not.
#
# And a real fetch, on one page: a wrong-but-well-shaped path (a renamed file,
# a moved directory) looks fine as a string. The fetch goes through
# raw.githubusercontent.com because github.com/.../edit/... redirects anyone
# who is not signed in to a login page, whether or not the file is there, so
# its status code cannot tell a real path from a typo.
#
# Only /docs/pipes is fetched, and its file is already on main. A pull request
# that ADDS a doc page therefore does not go red here for a file main has not
# got yet, while the shape check still covers the new page.
EDIT_BASE="https://github.com/beatzball/preen/edit/main/site/content/docs"

edit_link() {
  # tr puts every tag on its own line, so the anchor can be matched from the
  # start and the href picked off it.
  body "$BASE$1" | tr '<' '\n' |
    sed -n 's|^a href="\(https://github\.com/[^"]*/edit/[^"]*\)".*|\1|p' | head -1
}

check_edit_link() {
  path="$1"; want="$2"
  url=$(edit_link "$path")
  if [ -z "$url" ]; then bad "$path has no \"Edit this page\" link"; return; fi
  if [ "$url" != "$want" ]; then
    bad "$path edit link is $url"
    bad "  expected $want"
    return
  fi
  note "edit link ok  $path"
}

check_edit_link_resolves() {
  path="$1"
  url=$(edit_link "$path")
  [ -n "$url" ] || return   # already reported by check_edit_link
  raw=$(printf '%s\n' "$url" |
    sed -n 's|^https://github\.com/\([^/]*\)/\([^/]*\)/edit/\([^/]*\)/\(.*\)$|https://raw.githubusercontent.com/\1/\2/\3/\4|p')
  if [ -z "$raw" ]; then bad "$path edit link is not a github edit URL: $url"; return; fi
  code=$(status "$raw")
  if [ "$code" = "200" ]; then note "edit link resolves  $path"
  else bad "$path edit link points at a file that is not there ($code): $url"; fi
}

while IFS= read -r path; do
  case "$path" in /docs/*) ;; *) continue ;; esac
  slug=${path#/docs/}
  check_edit_link "$path" "$EDIT_BASE/$slug.md"
done <<EOF
$PAGES
EOF

check_edit_link_resolves /docs/pipes

# A 404 that returns 200 means try_files is misconfigured and every typo looks
# like a real page.
code=$(status "$BASE/definitely-not-a-page")
if [ "$code" = "404" ]; then note "404  /definitely-not-a-page (as expected)"
else bad "unknown path returned $code, expected 404"; fi

[ "$fail" -eq 0 ] || { printf 'verify-site: FAILED\n' >&2; exit 1; }
printf 'verify-site: OK\n'
