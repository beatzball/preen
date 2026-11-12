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
# is taken from the OLDEST undeployed site/ commit, so a fresh site change on
# top of an old missed one cannot hide the old one.
#
# Env:
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

err() { printf '::error::%s\n' "$*"; exit 1; }

head_sha=$(git rev-parse --verify 'HEAD^{commit}')

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
# --reverse with sed rather than `head -1`: under `set -o pipefail` a
# `git log | head -1` can die of SIGPIPE when head exits first, and that would
# fail this step for a reason that has nothing to do with drift.
oldest=$(git log --reverse --format='%H %ct' "$served..$head_sha" -- site/ | sed -n 1p)
[ -n "$oldest" ] ||
  err "site/ differs between $served and $head_sha, but no commit between them touches site/. Read the history by hand."
oldest_sha=${oldest% *}
oldest_ct=${oldest#* }
age_min=$(( (now - oldest_ct) / 60 ))

echo "site/ changes on main that production does not have:"
git log --format='  %h %cI %s' "$served..$head_sha" -- site/

if [ "$age_min" -lt "$grace_min" ]; then
  echo "pending  the oldest is $age_min min old, under the $grace_min min grace for CI and the Coolify build."
  exit 0
fi
err "production is missing site/ changes from main. The oldest, $(git log -1 --format=%h "$oldest_sha"), landed $age_min min ago (grace is $grace_min min). A deploy was skipped or failed: look at the ci runs on main since then, and redeploy."
