#!/usr/bin/env bash
# Apply one group of the standard GitHub settings to a repository, or check it for drift.
#
#   ./rulesets/apply.sh [--check] <group> <owner/repo> [check ...]
#   ./rulesets/apply.sh --migrate [--allow-dropped-checks] <owner/repo> [check ...]
#
# Groups, each defined by the JSON file of the same name beside this script:
#
#   branch-safety     ruleset: no deletion, no force-push             every repo
#   pr-flow           ruleset: PR required, review threads resolved   every repo
#   required-checks   ruleset: the named checks must pass             repos that run CI
#   repo-settings     wiki off, projects off, delete branch on merge  every repo
#   labels            claude-review (orange); retired names renamed   every repo
#
# The three rulesets are separate on purpose. GitHub adds rulesets together, so a repo
# with no CI takes the first two and skips the third, and correcting one repo's check
# list is a write that cannot touch its PR rules.
#
# `check` names a required status check and is only meaningful for required-checks
# (and --migrate). It is the one thing a repo is expected to differ on; checks.json
# says which reusable workflow reports which name. Quote names: "ci / CI" has spaces.
#
# --check exits 1 on drift and prints the difference, 0 on a match. Without it the group
# is written and the result reported. Exit 2 is a usage or environment error, never
# drift -- a caller gating on this needs to tell "differs" from "could not look".
#
# --migrate moves a repo from the old single `protect-main` ruleset to the three groups:
# it writes them, reads them back, and only then deletes protect-main. The repo is never
# without protection, because for a moment it has both.
#
# Needs a token with admin on the target repo -- the ambient `gh` token if you own it.
# GITHUB_TOKEN in Actions is NOT sufficient for the rulesets API, which is why nothing
# here runs unattended.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY="protect-main"

usage() {
  cat >&2 <<EOF
usage: $0 [--check] <group> <owner/repo> [check ...]
       $0 --migrate [--allow-dropped-checks] <owner/repo> [check ...]
groups: branch-safety, pr-flow, required-checks, repo-settings, labels
EOF
  exit 2
}

MODE=apply
ALLOW_DROPPED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --migrate) MODE=migrate ;;
    --allow-dropped-checks) ALLOW_DROPPED=true ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done

GROUP=""
if [ "$MODE" != migrate ]; then
  GROUP="${1:-}"
  [ -n "$GROUP" ] || usage
  shift
  case "$GROUP" in
    branch-safety | pr-flow | required-checks | repo-settings | labels) ;;
    *)
      echo "unknown group: $GROUP" >&2
      usage
      ;;
  esac
fi

REPO="${1:-}"
case "$REPO" in
  */*) shift ;;
  *) usage ;;
esac

for cmd in gh jq diff; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd is required" >&2
    exit 2
  }
done

# Built as JSON rather than shell words because a check name contains a space --
# "ci / CI" -- and word-splitting it would silently require two checks that do not
# exist. Sorted and de-duplicated so the order they were typed in is never drift.
CHECKS_JSON=$(printf '%s\n' "$@" | jq -R 'select(length > 0) | {context: .}' |
  jq -s 'unique_by(.context)')
N_CHECKS=$(jq 'length' <<<"$CHECKS_JSON")

# The group file as GitHub should hold it. Any `_comment*` key is documentation for
# humans; strip them all rather than one by name, so the next one added does not
# silently start being sent to the API.
desired_ruleset() {
  jq --argjson checks "$CHECKS_JSON" '
    with_entries(select(.key | startswith("_comment") | not))
    | .rules |= map(
        if .type == "required_status_checks"
        then .parameters.required_status_checks = $checks
        else . end)
  ' "$HERE/$1.json"
}

# Only the fields a group file claims to own. The live ruleset also carries an id,
# timestamps, _links and node ids, none of which are ours to assert. Rules and checks
# are sorted and keys ordered (-S), so ORDER is never reported as drift.
owned() {
  jq -S '{name, target, enforcement, conditions, bypass_actors,
          rules: (.rules
            | map(if .type == "required_status_checks"
                  then .parameters.required_status_checks |= sort_by(.context)
                  else . end)
            | sort_by(.type))}'
}

# The listing is checked for FAILURE separately from emptiness. Both produce no id, and
# they need opposite responses: an unreadable listing (the rulesets API wants admin, and
# a plain GITHUB_TOKEN may not have it) is an error to report, while an empty one is a
# repo that legitimately has no ruleset yet. Collapsing them would print "no ruleset
# named ..." at a repo that has one, and send whoever reads it to the wrong place.
LISTING=""
read_listing() {
  if ! LISTING=$(gh api "repos/$REPO/rulesets?per_page=100" 2>&1); then
    echo "ERROR: cannot read rulesets for $REPO -- the API needs admin on the repo." >&2
    echo "       A plain GITHUB_TOKEN is usually not enough. Response was:" >&2
    printf '       %s\n' "$LISTING" >&2
    exit 2
  fi
}

# Resolve by NAME, never a hardcoded id: the id differs per repo. Repository-level only
# -- the listing also returns rulesets inherited from the organisation, and one of
# those sharing a name is not ours to update.
ruleset_id() {
  printf '%s' "$LISTING" | jq -r --arg name "$1" '
    [.[] | select(.name == $name and (.source_type // "Repository") == "Repository") | .id]
    | first // empty' 2>/dev/null || true
}

# $1 group, $2 check|apply. Returns 0 when the repo matches (or was made to), 1 on drift.
sync_ruleset() {
  local group="$1" mode="$2" want id live
  if [ "$group" = required-checks ] && [ "$N_CHECKS" -eq 0 ]; then
    echo "required-checks needs at least one check name, e.g. 'ci / CI'." >&2
    echo "A required-checks ruleset with no checks is not written: a repo with no CI" >&2
    echo "simply does not take this group." >&2
    exit 2
  fi

  want=$(desired_ruleset "$group")
  id=$(ruleset_id "$group")

  if [ -z "$id" ]; then
    if [ "$mode" = check ]; then
      echo "DRIFT: $REPO has no ruleset named $group" >&2
      if [ -n "$(ruleset_id "$LEGACY")" ]; then
        echo "       (it still has the old $LEGACY ruleset: $0 --migrate $REPO [check ...])" >&2
      fi
      return 1
    fi
    echo "$REPO: creating $group"
    printf '%s' "$want" | gh api "repos/$REPO/rulesets" -X POST --input - \
      --jq '"created ruleset \(.id)"'
    return 0
  fi

  live=$(gh api "repos/$REPO/rulesets/$id" | owned)
  if [ "$live" = "$(owned <<<"$want")" ]; then
    echo "$REPO: $group matches"
    return 0
  fi

  if [ "$mode" = check ]; then
    echo "DRIFT: $REPO/$group differs from rulesets/$group.json" >&2
    echo "--- live (GitHub)   +++ standard (this repo) ---" >&2
    diff <(printf '%s\n' "$live") <(owned <<<"$want") >&2 || true
    return 1
  fi

  echo "$REPO: updating $group (ruleset $id)"
  # PUT, not PATCH: it replaces the whole ruleset, which is what makes re-applying
  # remove a rule that was only ever added by hand.
  printf '%s' "$want" | gh api "repos/$REPO/rulesets/$id" -X PUT --input - \
    --jq '"applied: " + ([.rules[].type] | join(", "))'
}

# $1 check|apply. Compares and writes ONLY the keys repo-settings.json lists.
sync_settings() {
  local mode="$1" want live response
  want=$(jq -S 'with_entries(select(.key | startswith("_comment") | not))' \
    "$HERE/repo-settings.json")
  if ! live=$(gh api "repos/$REPO" 2>&1); then
    echo "ERROR: cannot read $REPO. Response was:" >&2
    printf '       %s\n' "$live" >&2
    exit 2
  fi
  live=$(jq -S --argjson want "$want" \
    'with_entries(select(.key as $k | $want | has($k)))' <<<"$live")

  if [ "$live" = "$want" ]; then
    echo "$REPO: repo-settings matches"
    return 0
  fi
  if [ "$mode" = check ]; then
    echo "DRIFT: $REPO settings differ from rulesets/repo-settings.json" >&2
    echo "--- live (GitHub)   +++ standard (this repo) ---" >&2
    diff <(printf '%s\n' "$live") <(printf '%s\n' "$want") >&2 || true
    return 1
  fi
  echo "$REPO: updating repo-settings"
  response=$(printf '%s' "$want" | gh api "repos/$REPO" -X PATCH --input -)
  # Report what GitHub says the values are now, not what was sent.
  echo "applied: $(jq -c --argjson want "$want" \
    'with_entries(select(.key as $k | $want | has($k)))' <<<"$response")"
}

# $1 check|apply. The labels labels.json owns, and the retired names it replaces.
# Compared case-insensitively on colour (GitHub returns lowercase hex), exactly on the
# description. A name is URL-encoded for the path: "claude-review:opus" has a colon.
label_path() { printf 'repos/%s/labels/%s' "$REPO" "$(jq -rn --arg n "$1" '$n | @uri')"; }

read_labels() { # -> JSON object {name: {color, description}} of every label on the repo
  local raw
  if ! raw=$(gh api "repos/$REPO/labels?per_page=100" --paginate --jq '.[]' 2>&1); then
    echo "ERROR: cannot read labels for $REPO. Response was:" >&2
    printf '       %s\n' "$raw" >&2
    exit 2
  fi
  jq -s 'map({key: .name, value: {color: (.color | ascii_downcase), description: (.description // "")}})
         | from_entries' <<<"$raw"
}

# What is wrong, one line each: a wanted label that is absent or different, and a retired
# label that is still there. $1 is the live labels object. Empty output means it matches.
label_issues() {
  jq -S '.labels | with_entries(.value.color |= ascii_downcase)' "$HERE/labels.json" |
    jq -r --argjson live "$1" --slurpfile f "$HERE/labels.json" '
      ( to_entries[]
        | select(($live[.key]) != .value)
        | if $live[.key] == null then "missing: \(.key)"
          else "differs: \(.key) (live \($live[.key] | tojson), standard \(.value | tojson))" end ),
      ( $f[0].renamed_from | keys[] | select($live[.] != null) | "retired, still present: \(.)" )'
}

sync_labels() {
  local mode="$1" want live from to issues
  want=$(jq -S '.labels | with_entries(.value.color |= ascii_downcase)' "$HERE/labels.json")
  live=$(read_labels)
  issues=$(label_issues "$live")

  if [ -z "$issues" ]; then
    echo "$REPO: labels match"
    return 0
  fi
  if [ "$mode" = check ]; then
    echo "DRIFT: $REPO labels differ from rulesets/labels.json" >&2
    printf '  %s\n' "$issues" >&2
    return 1
  fi

  echo "$REPO: updating labels"
  # Renames first. If the replacement name already exists it is deleted, and the retired
  # label renamed over it -- that keeps the retired label's PRs labelled.
  while IFS=$'\t' read -r from to; do
    [ -n "$from" ] || continue
    [ "$(jq --arg n "$from" 'has($n)' <<<"$live")" = true ] || continue
    if [ "$(jq --arg n "$to" 'has($n)' <<<"$live")" = true ]; then
      echo "  deleting $to (replaced by $from)"
      gh api "$(label_path "$to")" -X DELETE >/dev/null
    fi
    echo "  renaming $from -> $to"
    jq -n --arg to "$to" --argjson w "$(jq --arg n "$to" '.[$n]' <<<"$want")" \
      '{new_name: $to, color: $w.color, description: $w.description}' |
      gh api "$(label_path "$from")" -X PATCH --input - >/dev/null
  done < <(jq -r '.renamed_from | to_entries[] | [.key, .value] | @tsv' "$HERE/labels.json")

  live=$(read_labels)
  while IFS= read -r to; do
    if [ "$(jq --arg n "$to" 'has($n) | not' <<<"$live")" = true ]; then
      echo "  creating $to"
      jq -n --arg n "$to" --argjson w "$(jq --arg n "$to" '.[$n]' <<<"$want")" \
        '{name: $n, color: $w.color, description: $w.description}' |
        gh api "repos/$REPO/labels" -X POST --input - >/dev/null
    elif [ "$(jq --argjson want "$want" --arg n "$to" '.[$n] != $want[$n]' <<<"$live")" = true ]; then
      echo "  updating $to"
      jq --arg n "$to" '.[$n]' <<<"$want" | gh api "$(label_path "$to")" -X PATCH --input - >/dev/null
    fi
  done < <(jq -r 'keys[]' <<<"$want")

  # Read back from GitHub rather than trust the writes.
  issues=$(label_issues "$(read_labels)")
  if [ -n "$issues" ]; then
    echo "ERROR: $REPO labels still differ after writing:" >&2
    printf '  %s\n' "$issues" >&2
    return 1
  fi
  echo "applied: labels"
}

migrate() {
  local old_id old dropped extra bypass groups group
  read_listing
  old_id=$(ruleset_id "$LEGACY")

  if [ -n "$old_id" ]; then
    old=$(gh api "repos/$REPO/rulesets/$old_id")

    # A check the old ruleset required and the new list does not would stop being
    # required the moment protect-main is deleted -- silently, with nothing red. Refuse
    # before writing anything, and make dropping one a decision someone typed.
    dropped=$(jq -c --argjson new "$CHECKS_JSON" '
      [.rules[] | select(.type == "required_status_checks")
       | .parameters.required_status_checks[].context] - ($new | map(.context))' <<<"$old")
    if [ "$dropped" != "[]" ] && ! $ALLOW_DROPPED; then
      echo "REFUSING: $REPO/$LEGACY requires checks the new list does not: $dropped" >&2
      echo "Pass them as arguments to keep them required, or --allow-dropped-checks if" >&2
      echo "no workflow reports them any more. Nothing was changed." >&2
      exit 1
    fi
    [ "$dropped" = "[]" ] || echo "$REPO: no longer required after migration: $dropped"

    extra=$(jq -c '[.rules[].type]
      - ["deletion", "non_fast_forward", "pull_request", "required_status_checks"]' <<<"$old")
    [ "$extra" = "[]" ] || echo "$REPO: rules in $LEGACY that no group carries, so they go: $extra"
    bypass=$(jq '.bypass_actors | length' <<<"$old")
    [ "$bypass" -eq 0 ] || echo "$REPO: $LEGACY had $bypass bypass actor(s); the groups have none"
  fi

  groups="branch-safety pr-flow"
  if [ "$N_CHECKS" -gt 0 ]; then
    groups="$groups required-checks"
  else
    echo "$REPO: no checks given, so no required-checks ruleset"
  fi

  for group in $groups; do sync_ruleset "$group" apply; done

  # Read back from GitHub rather than trusting the writes: the old ruleset is only
  # deleted once every group is confirmed live and identical to its file.
  read_listing
  for group in $groups; do
    if ! sync_ruleset "$group" check; then
      echo "REFUSING to delete $LEGACY: $group is not in place on $REPO." >&2
      exit 1
    fi
  done

  if [ -n "$old_id" ]; then
    echo "$REPO: deleting $LEGACY (ruleset $old_id)"
    gh api "repos/$REPO/rulesets/$old_id" -X DELETE
  else
    echo "$REPO: no $LEGACY ruleset to remove"
  fi
}

case "$MODE" in
  migrate) migrate ;;
  *)
    if [ "$GROUP" = repo-settings ]; then
      sync_settings "$MODE"
    elif [ "$GROUP" = labels ]; then
      sync_labels "$MODE"
    else
      read_listing
      sync_ruleset "$GROUP" "$MODE"
    fi
    ;;
esac
