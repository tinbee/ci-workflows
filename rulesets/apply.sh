#!/usr/bin/env bash
# Apply the canonical protect-main ruleset to a repository, or check it for drift.
#
#   ./rulesets/apply.sh <owner/repo> [extra-check ...]
#   ./rulesets/apply.sh --check <owner/repo> [extra-check ...]
#
# `extra-check` names a required status check this repo needs beyond the canonical
# "ci / CI" -- envmesh, for instance, also requires "scope / pr-scope-guard". That list
# is the only field a consumer is expected to differ on; anything else differing is
# drift rather than configuration.
#
# --check exits 1 on drift and prints the difference, so a workflow can gate on it.
# Without it the ruleset is written and the result read back.
#
# Needs a token with admin on the target repo -- the ambient `gh` token if you own it.
# GITHUB_TOKEN in Actions is NOT sufficient for the rulesets API, which is why the
# drift guard checks rather than corrects.
set -euo pipefail

CHECK_ONLY=false
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=true
  shift
fi

REPO="${1:-}"
if [ -z "$REPO" ]; then
  echo "usage: $0 [--check] <owner/repo> [extra-check ...]" >&2
  exit 2
fi
shift || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="$HERE/protect-main.json"
[ -f "$CANONICAL" ] || { echo "missing $CANONICAL" >&2; exit 2; }

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 2; }
done

# The repo's full required-check list: canonical plus whatever it was given. Built as
# JSON rather than shell words because a check name contains a space -- "ci / CI" -- and
# word-splitting it would silently require two checks that do not exist.
extra_json=$(printf '%s\n' "$@" | jq -R 'select(length > 0) | {context: .}' | jq -s .)

# Any `_comment*` key is documentation for humans. GitHub ignores unknown members, but
# strip them all rather than one by name -- the file has more than one such key, and the
# next one added should not silently start being sent to the API.
desired=$(jq --argjson extra "$extra_json" '
  with_entries(select(.key | startswith("_comment") | not))
  | .rules = (.rules | map(
      if .type == "required_status_checks"
      then .parameters.required_status_checks = (.parameters.required_status_checks + $extra)
      else . end))
' "$CANONICAL")

# Resolve the ruleset by NAME, never a hardcoded id: the id differs per repo (foliot
# 22110646, envmesh 15884682, instastack 24102040).
#
# The listing is checked for FAILURE separately from emptiness. Both produce no id, and
# they need opposite responses: an unreadable listing (the rulesets API wants admin, and
# a plain GITHUB_TOKEN may not have it) is an error to report, while an empty one is a
# repo that legitimately has no ruleset yet. Collapsing them would let a guard print
# "no ruleset named protect-main" at a repo that has one, and send whoever reads it to
# the wrong place entirely.
if ! listing=$(gh api "repos/$REPO/rulesets" 2>&1); then
  echo "ERROR: cannot read rulesets for $REPO -- the API needs admin on the repo." >&2
  echo "       A plain GITHUB_TOKEN is usually not enough. Response was:" >&2
  printf '       %s\n' "$listing" >&2
  exit 2
fi
id=$(printf '%s' "$listing" | jq -r '.[] | select(.name=="protect-main") | .id' 2>/dev/null || true)

if [ -z "$id" ]; then
  if $CHECK_ONLY; then
    echo "DRIFT: $REPO has no ruleset named protect-main" >&2
    exit 1
  fi
  echo "$REPO: creating protect-main"
  printf '%s' "$desired" | gh api "repos/$REPO/rulesets" -X POST --input - --jq '"created ruleset \(.id)"'
  exit 0
fi

# Compare only the fields the canonical file claims to own. The live ruleset also
# carries an id, timestamps, _links and node ids, none of which are ours to assert.
live=$(gh api "repos/$REPO/rulesets/$id" |
  jq '{name, target, enforcement, conditions, rules, bypass_actors}')
want=$(printf '%s' "$desired" |
  jq '{name, target, enforcement, conditions, rules, bypass_actors}')

# Sort keys on both sides, so key ORDER is never reported as drift.
if [ "$(jq -S . <<<"$live")" = "$(jq -S . <<<"$want")" ]; then
  echo "$REPO: protect-main matches the canonical ruleset"
  exit 0
fi

if $CHECK_ONLY; then
  echo "DRIFT: $REPO/protect-main differs from rulesets/protect-main.json" >&2
  echo "--- live (GitHub)   +++ canonical (this repo) ---" >&2
  diff <(jq -S . <<<"$live") <(jq -S . <<<"$want") >&2 || true
  exit 1
fi

echo "$REPO: updating protect-main (ruleset $id)"
printf '%s' "$desired" | gh api "repos/$REPO/rulesets/$id" -X PUT --input - \
  --jq '"applied: " + ([.rules[].type] | join(", "))'
