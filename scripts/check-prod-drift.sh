#!/bin/sh
# check-prod-drift.sh — fail when production is not serving main's site.
#
#   scripts/check-prod-drift.sh https://preening.dev
#
# Run from a checkout of main with full history. Used on a schedule by
# .github/workflows/prod-drift.yml.
#
# Why this exists (#40, #43): the deploy job runs only when a push to main
# changed site/, and only when everything it needs passed. If anything stops it
# -- a transient failure upstream, a skipped job, a webhook that queued a build
# Coolify then dropped -- the run that should have deployed goes red once, and
# every later push that does not touch site/ skips the deploy green. Production
# then serves an old site while the repository looks healthy. verify-prod
# cannot see this: it runs only after a deploy, so it never runs for the one
# that did not happen.
#
# What is compared, and why not main's HEAD. Production legitimately lags
# HEAD whenever the newest commits only touched bin/, tests/ or the workflow,
# because those never deploy. So the question is not "is production at HEAD"
# but "does production serve the site/ that main has":
#
#   git diff --quiet <served commit> HEAD -- site/
#
# That passes when production is at the last commit that touched site/, and
# also when it is at a later one (Coolify builds whatever main is when the
# queued build starts, and a manual redeploy builds HEAD). It fails only when
# a site/ change on main is not in what production serves.
#
# A deploy takes time: CI on main, then a Coolify build. So a site/ change
# younger than the grace period is reported as pending, not as drift. The age
# is taken from the OLDEST site/ commit that is still outstanding, so a fresh
# site change on top of an old missed one cannot hide the old one. "Still
# outstanding" matters: a site change that a later commit reverted, so that
# main's site/ matched production again, is not counted -- otherwise its age
# would be charged to the next, healthy deploy.
#
# The age is the commit's committer date, not when it reached main. With
# squash-only merges (this repository's setting) the two are the same moment.
# A merge commit or a direct push of an old commit would make a change look
# older than it is -- a false alarm, never a missed one -- and a commit dated
# in the future would look younger.
#
# Env:
#   PREEN_DRIFT_REMOTE      if set (CI sets "origin"), fetch that remote's main
#                           AFTER reading production, and compare against it
#                           rather than HEAD. A scheduled run can wait in a
#                           queue while main moves on and deploys, so the
#                           checkout alone can be older than production.
#   PREEN_DRIFT_GRACE_MIN   minutes a site/ change may wait to deploy (default 120)
#   PREEN_PROBE_RETRIES     attempts at reading /version.json (default 3)
#   PREEN_PROBE_DELAY       seconds between attempts (default 10)
#   PREEN_NOW               current time as epoch seconds (tests only)
set -eu

BASE="${1:?usage: check-prod-drift.sh BASE_URL}"
BASE="${BASE%/}"
grace_min="${PREEN_DRIFT_GRACE_MIN:-120}"
retries="${PREEN_PROBE_RETRIES:-3}"
delay="${PREEN_PROBE_DELAY:-10}"
now="${PREEN_NOW:-$(date +%s)}"

remote="${PREEN_DRIFT_REMOTE:-}"

err() { printf '::error::%s\n' "$*"; exit 1; }

# 1. What production serves. Retried, because one dropped request is not a
# missing deploy, and a false alarm every few weeks teaches people to ignore
# the real one.
n=0
served=""
while :; do
  n=$((n + 1))
  # An assignment carries the status of the substitution, and a pipeline's
  # status is sed's, which succeeds on empty input. So curl's failure is not
  # read from here at all: an empty $served is the one signal, and it covers
  # no answer, a 404 page and a version.json without a commit alike.
  served=$(curl -fsS --max-time 20 "$BASE/version.json" 2>/dev/null |
             sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p') || served=""
  [ -n "$served" ] && break
  [ "$n" -ge "$retries" ] &&
    err "$BASE/version.json gave no commit after $n attempts. Production is down, or is serving an image built without GIT_SHA."
  sleep "$delay"
done

# Main is read AFTER production, never before. Read first, a deploy of a newer
# main that lands between the two reads would be a commit this checkout has
# never seen, and step 2 would call a successful deploy a missing one.
if [ -n "$remote" ]; then
  git fetch --quiet "$remote" "+refs/heads/main:refs/remotes/$remote/main" ||
    err "could not fetch main from $remote, so production cannot be compared with it."
  head_sha=$(git rev-parse --verify "refs/remotes/$remote/main^{commit}")
else
  head_sha=$(git rev-parse --verify 'HEAD^{commit}')
fi
echo "production serves $served"
echo "main is at         $head_sha"

# 2. The served commit has to be one main knows. A commit missing from the
# checkout means production was built from a branch, or from history that a
# force-push rewrote -- either way, not from main.
git cat-file -e "$served^{commit}" 2>/dev/null ||
  err "production serves $served, which is not in this checkout of main."
git merge-base --is-ancestor "$served" "$head_sha" ||
  err "production serves $served, which is not on main's history."

# 3. The real question: does production have main's site/?
if git diff --quiet "$served" "$head_sha" -- site/; then
  last=$(git log -1 --format='%h %s' "$head_sha" -- site/)
  echo "ok  production has main's site/ (last site change: $last)"
  exit 0
fi

# 4. It does not. Pending, or missing?
#
# Per FILE, not per tree. For each file under site/ that production lacks,
# walk the commits since the served one that touched it, oldest first. A
# commit that leaves the file equal to production's again (a revert) clears
# that file's clock; the first one after that which does not is when its
# outstanding change started. The oldest of those starts is the age.
#
# Per file because a revert is not always the last word on the tree: an old
# change B, then a fresh unrelated page C, then a revert of B leaves only C
# missing -- but the whole tree never matches production again, so a
# tree-level walk would still charge B's age to C's healthy deploy. The
# granularity is the file: an old change and a fresh one in the SAME file,
# with the old one later reverted, still reads as old. Rare enough to accept;
# the cost is a false alarm, never a missed one.
#
# Paths are read one per line from a here-doc so the loop runs in this shell
# and its variables survive. Two things keep each name the real one:
#
#   core.quotepath=false  git otherwise prints a name with a non-ASCII byte
#                         as "site/caf\303\251.md", quotes and all, and that
#                         string matches no file
#   :(literal)            a name is a pathspec, where [ ] * ? are glob
#                         characters; site/pages/docs/[slug].ts is real
#
# A name git still quotes (a double quote, backslash, tab or newline in it)
# is the one case left, and it fails CLOSED below: a file whose history
# cannot be read stops the run, rather than dropping out of the age and
# letting a newer file make an old miss look pending.
oldest_sha=""
oldest_ct=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  start=""
  for c in $(git log --reverse --format=%H "$served..$head_sha" -- ":(literal)$p"); do
    if git diff --quiet "$served" "$c" -- ":(literal)$p"; then
      start=""
    elif [ -z "$start" ]; then
      start=$c
    fi
  done
  [ -n "$start" ] ||
    err "cannot read the history of $p, so its age is unknown. Read the history by hand."
  ct=$(git log -1 --format=%ct "$start")
  if [ -z "$oldest_ct" ] || [ "$ct" -lt "$oldest_ct" ]; then
    oldest_sha=$start
    oldest_ct=$ct
  fi
done <<EOF
$(git -c core.quotepath=false diff --name-only --no-renames "$served" "$head_sha" -- site/)
EOF
[ -n "$oldest_sha" ] ||
  err "site/ differs between $served and $head_sha, but no commit between them touches site/. Read the history by hand."
age_min=$(( (now - oldest_ct) / 60 ))

echo "site/ changes on main that production does not have:"
git log --format='  %h %cI %s' "$served..$head_sha" -- site/

if [ "$age_min" -lt "$grace_min" ]; then
  echo "pending  the oldest is $age_min min old, under the $grace_min min grace for CI and the Coolify build."
  exit 0
fi
err "production is missing site/ changes from main. The oldest, $(git log -1 --format=%h "$oldest_sha"), landed $age_min min ago (grace is $grace_min min). A deploy was skipped or failed: look at the ci runs on main since then, and redeploy."
