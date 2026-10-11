#!/usr/bin/env bash
# Tests for apply.sh and the group files. No network: `gh` is replaced by a small
# stateful fake that stores rulesets as files, so create / update / delete / read-back
# all behave the way the sequence in apply.sh depends on.
#
#   ./rulesets/selftest.sh
#
# Each drift case INJECTS a difference and requires apply.sh to see it. A comparison
# that only ever ran against matching data is indistinguishable from one that is blind.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APPLY="$HERE/apply.sh"
RULESET_GROUPS="branch-safety pr-flow required-checks"

for cmd in jq yq diff; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd is required" >&2
    exit 2
  }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# --- the fake -----------------------------------------------------------------------
# Understands exactly the calls apply.sh makes:
#   gh api <path> [-X METHOD] [--input -] [--jq EXPR]
# State lives under $FAKE_STATE: rulesets/<id>.json and repo.json. Every call is logged
# to calls.log as "METHOD path", which is how a test asserts that --check wrote nothing.
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || { echo "fake gh: only 'api' is implemented" >&2; exit 2; }
shift
path="$1"; shift
method=GET; jqexpr=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --input) body=$(cat); shift ;;
    --jq) jqexpr="$2"; shift ;;
    *) echo "fake gh: unexpected argument $1" >&2; exit 2 ;;
  esac
  shift
done
path="${path%%\?*}"
echo "$method $path" >>"$FAKE_STATE/calls.log"
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
rs="$FAKE_STATE/rulesets"

case "$method $path" in
  "GET repos/"*/rulesets)
    if [ -n "${FAKE_FAIL_LISTING:-}" ]; then echo "gh: Not Found (HTTP 404)"; exit 1; fi
    for f in "$rs"/*.json; do if [ -e "$f" ]; then cat "$f"; fi; done |
      jq -s 'map({id, name, target, enforcement, source_type})' | emit ;;
  "POST repos/"*/rulesets)
    id=$(($(cat "$FAKE_STATE/next_id") + 1)); echo "$id" >"$FAKE_STATE/next_id"
    stored=$(jq --argjson id "$id" '. + {id: $id, source_type: "Repository", node_id: "RRS_x"}' <<<"$body")
    [ -n "${FAKE_IGNORE_WRITES:-}" ] || printf '%s' "$stored" >"$rs/$id.json"
    printf '%s' "$stored" | emit ;;
  "GET repos/"*/rulesets/*)
    emit <"$rs/${path##*/}.json" ;;
  "PUT repos/"*/rulesets/*)
    id="${path##*/}"
    stored=$(jq --argjson id "$id" '. + {id: $id, source_type: "Repository", node_id: "RRS_x"}' <<<"$body")
    [ -n "${FAKE_IGNORE_WRITES:-}" ] || printf '%s' "$stored" >"$rs/$id.json"
    printf '%s' "$stored" | emit ;;
  "DELETE repos/"*/rulesets/*)
    rm "$rs/${path##*/}.json" ;;
  "GET repos/"*)
    emit <"$FAKE_STATE/repo.json" ;;
  "PATCH repos/"*)
    merged=$(jq --argjson b "$body" '. + $b' "$FAKE_STATE/repo.json")
    printf '%s' "$merged" >"$FAKE_STATE/repo.json"
    printf '%s' "$merged" | emit ;;
  *) echo "fake gh: unhandled $method $path" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export FAKE_STATE="$WORK/state"

# A fresh, empty repo: no rulesets, settings at GitHub's defaults.
reset_state() {
  rm -rf "$FAKE_STATE"
  mkdir -p "$FAKE_STATE/rulesets"
  echo 100 >"$FAKE_STATE/next_id"
  : >"$FAKE_STATE/calls.log"
  echo '{"name":"demo","has_wiki":true,"has_projects":true,"delete_branch_on_merge":false,"has_issues":true}' \
    >"$FAKE_STATE/repo.json"
}

FAILED=0
PASSED=0
ok() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL: $*" >&2
}

# expect <code> <description> <apply.sh args...>
expect() {
  local want="$1" what="$2" got=0
  shift 2
  "$APPLY" "$@" >"$WORK/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    ok
  else
    fail "$what: exit $got, wanted $want"
    sed 's/^/    /' "$WORK/out" >&2
  fi
}

writes() { grep -cvE '^GET ' "$FAKE_STATE/calls.log" || true; }
names() { cat "$FAKE_STATE"/rulesets/*.json 2>/dev/null | jq -s -c 'map(.name) | sort'; }
is() { # is <description> <got> <want>
  if [ "$2" = "$3" ]; then ok; else fail "$1: got $2, wanted $3"; fi
}
# Rewrite the stored ruleset named $1 with the jq program $2, as if edited by hand.
tamper() {
  local f
  for f in "$FAKE_STATE"/rulesets/*.json; do
    [ "$(jq -r .name "$f")" = "$1" ] || continue
    jq "$2" "$f" >"$f.t" && mv "$f.t" "$f"
    return 0
  done
  fail "tamper: no stored ruleset named $1"
}

REPO=acme/demo

# --- 1. the group files themselves --------------------------------------------------
for group in $RULESET_GROUPS; do
  f="$HERE/$group.json"
  is "$group.json: name matches the filename" "$(jq -r .name "$f")" "$group"
  is "$group.json: no bypass actors" "$(jq -c .bypass_actors "$f")" "[]"
  is "$group.json: targets the default branch" \
    "$(jq -c .conditions.ref_name.include "$f")" '["~DEFAULT_BRANCH"]'
  is "$group.json: no copilot_code_review rule" \
    "$(jq '[.rules[] | select(.type == "copilot_code_review")] | length' "$f")" "0"
done
# Together the three must carry exactly the rules the single ruleset did.
is "the groups together carry the four standard rules" \
  "$(for g in $RULESET_GROUPS; do jq -r '.rules[].type' "$HERE/$g.json"; done | sort | tr '\n' ' ')" \
  "deletion non_fast_forward pull_request required_status_checks "

# --- 2. checks.json agrees with the workflows ---------------------------------------
for wf in "$ROOT"/.github/workflows/*.yml; do
  base="$(basename "$wf")"
  [ "$(yq -r '.on | has("workflow_call")' "$wf")" = true ] || continue
  actual=$(yq -o=json '[.jobs | to_entries[] | (.value.name // .key)] | sort' "$wf" | jq -c .)
  listed=$(jq -c --arg f "$base" '.workflows[$f].jobs // null | if . then sort else . end' "$HERE/checks.json")
  is "checks.json lists the jobs of $base" "$listed" "$actual"
done
# `expects` marks a workflow a repo is wrong to lack, so it belongs only on a gate, and
# it is exactly one of {file} or {language} with a non-empty string.
is "expects appears only on gate workflows" \
  "$(jq -c '[.workflows | to_entries[] | select(.value.expects and .value.gate != true) | .key]' "$HERE/checks.json")" "[]"
is "every expects names one file or one language" \
  "$(jq -c '[.workflows | to_entries[] | select(.value.expects)
      | select((.value.expects | keys) as $k
          | (($k == ["file"] or $k == ["language"])
             and (.value.expects[$k[0]] | type == "string" and length > 0)) | not)
      | .key]' "$HERE/checks.json")" "[]"
for base in $(jq -r '.workflows | keys[]' "$HERE/checks.json"); do
  if [ -f "$ROOT/.github/workflows/$base" ]; then ok; else fail "checks.json names $base, which does not exist"; fi
done

# --- 3. check on a repo with nothing is drift, and writes nothing --------------------
reset_state
expect 1 "check branch-safety on an empty repo" --check branch-safety "$REPO"
expect 1 "check pr-flow on an empty repo" --check pr-flow "$REPO"
expect 1 "check required-checks on an empty repo" --check required-checks "$REPO" 'ci / CI'
is "--check made no writes" "$(writes)" "0"

# --- 4. apply, then check is clean ---------------------------------------------------
expect 0 "apply branch-safety" branch-safety "$REPO"
expect 0 "apply pr-flow" pr-flow "$REPO"
expect 0 "apply required-checks" required-checks "$REPO" 'ci / CI' 'go / CI'
is "three rulesets exist" "$(names)" '["branch-safety","pr-flow","required-checks"]'
expect 0 "check branch-safety after apply" --check branch-safety "$REPO"
expect 0 "check pr-flow after apply" --check pr-flow "$REPO"
expect 0 "check required-checks after apply" --check required-checks "$REPO" 'ci / CI' 'go / CI'
expect 0 "order of check names is not drift" --check required-checks "$REPO" 'go / CI' 'ci / CI'
# A name with spaces must arrive as ONE check, not three words.
is "check names keep their spaces" \
  "$(cat "$FAKE_STATE"/rulesets/*.json | jq -s -c '[.[] | select(.name == "required-checks") | .rules[0].parameters.required_status_checks[].context]')" \
  '["ci / CI","go / CI"]'
expect 0 "a check named twice is still a match" --check required-checks "$REPO" 'ci / CI' 'go / CI' 'ci / CI'
before=$(writes)
expect 0 "apply when already matching" pr-flow "$REPO"
is "apply on a matching ruleset writes nothing" "$(writes)" "$before"

# --- 5. injected drift is seen, in each direction ------------------------------------
tamper pr-flow '.rules += [{type: "copilot_code_review", parameters: {review_on_push: true}}]'
expect 1 "an added rule is drift" --check pr-flow "$REPO"
expect 0 "apply removes the added rule" pr-flow "$REPO"
expect 0 "pr-flow is clean again" --check pr-flow "$REPO"

tamper pr-flow '(.rules[] | select(.type == "pull_request") | .parameters.required_review_thread_resolution) = false'
expect 1 "a changed parameter is drift" --check pr-flow "$REPO"
expect 0 "apply restores the parameter" pr-flow "$REPO"
expect 0 "pr-flow is clean after the restore" --check pr-flow "$REPO"

tamper pr-flow '.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]'
expect 1 "a bypass actor is drift" --check pr-flow "$REPO"
expect 0 "apply removes the bypass actor" pr-flow "$REPO"

tamper branch-safety '.enforcement = "disabled"'
expect 1 "a disabled ruleset is drift" --check branch-safety "$REPO"
expect 0 "apply re-enables it" branch-safety "$REPO"

tamper branch-safety '.rules |= map(select(.type != "deletion"))'
expect 1 "a removed rule is drift" --check branch-safety "$REPO"

expect 1 "a missing required check is drift" --check required-checks "$REPO" 'ci / CI' 'go / CI' 'scope / pr-scope-guard'
expect 1 "an extra required check is drift" --check required-checks "$REPO" 'ci / CI'

# --- 6. errors are not drift ---------------------------------------------------------
expect 2 "required-checks with no check names" required-checks "$REPO"
expect 2 "required-checks --check with no check names" --check required-checks "$REPO"
expect 2 "unknown group" --check nonsense "$REPO"
expect 2 "repo without an owner" --check pr-flow demo
expect 2 "no arguments"
export FAKE_FAIL_LISTING=1
expect 2 "an unreadable listing is an error, not 'missing'" --check pr-flow "$REPO"
unset FAKE_FAIL_LISTING

# An organisation ruleset that happens to share a name is not the repo's to update.
reset_state
jq -n '{id: 9, name: "pr-flow", target: "branch", enforcement: "active", source_type: "Organization",
  conditions: {}, rules: [], bypass_actors: []}' >"$FAKE_STATE/rulesets/9.json"
expect 1 "an inherited ruleset of the same name does not count" --check pr-flow "$REPO"
expect 0 "apply creates the repo's own beside it" pr-flow "$REPO"
is "the inherited ruleset was not overwritten" "$(jq -c .rules "$FAKE_STATE/rulesets/9.json")" "[]"
expect 0 "the repo's own pr-flow is clean" --check pr-flow "$REPO"

# --- 7. repo-settings ----------------------------------------------------------------
reset_state
expect 1 "check repo-settings on defaults" --check repo-settings "$REPO"
is "--check repo-settings made no writes" "$(writes)" "0"
expect 0 "apply repo-settings" repo-settings "$REPO"
expect 0 "check repo-settings after apply" --check repo-settings "$REPO"
is "settings it owns are set" \
  "$(jq -c '{has_wiki, has_projects, delete_branch_on_merge}' "$FAKE_STATE/repo.json")" \
  '{"has_wiki":false,"has_projects":false,"delete_branch_on_merge":true}'
is "a setting it does not list is untouched" "$(jq -r .has_issues "$FAKE_STATE/repo.json")" "true"

# --- 8. migrate ----------------------------------------------------------------------
legacy() {
  reset_state
  jq -n '{id: 7, name: "protect-main", target: "branch", enforcement: "active", source_type: "Repository",
    conditions: {ref_name: {include: ["refs/heads/main"], exclude: []}}, bypass_actors: [],
    rules: [{type: "deletion"}, {type: "non_fast_forward"},
      {type: "required_status_checks", parameters: {strict_required_status_checks_policy: true,
        do_not_enforce_on_create: false,
        required_status_checks: [{context: "ci / CI"}, {context: "scope / pr-scope-guard"}]}},
      {type: "pull_request", parameters: {required_approving_review_count: 0}},
      {type: "copilot_code_review", parameters: {review_on_push: false}}]}' >"$FAKE_STATE/rulesets/7.json"
}

legacy
expect 1 "migrate refuses to drop a required check silently" --migrate "$REPO" 'ci / CI'
is "a refused migration wrote nothing" "$(writes)" "0"
is "a refused migration leaves protect-main" "$(names)" '["protect-main"]'

legacy
expect 0 "migrate with the full check list" --migrate "$REPO" 'ci / CI' 'scope / pr-scope-guard'
is "after migrate: three groups, no protect-main" "$(names)" '["branch-safety","pr-flow","required-checks"]'
expect 0 "after migrate: pr-flow is clean" --check pr-flow "$REPO"

legacy
expect 0 "migrate may drop a check when told to" --migrate --allow-dropped-checks "$REPO" 'ci / CI'
is "after an allowed drop: protect-main is gone" "$(names)" '["branch-safety","pr-flow","required-checks"]'

# If the writes do not land, the old ruleset must survive.
legacy
export FAKE_IGNORE_WRITES=1
expect 1 "migrate stops when the groups are not in place" --migrate "$REPO" 'ci / CI' 'scope / pr-scope-guard'
unset FAKE_IGNORE_WRITES
is "protect-main survives a failed migration" "$(names)" '["protect-main"]'

# A repo with no CI: two groups, no required-checks, nothing left over.
reset_state
expect 0 "migrate a repo with no ruleset and no checks" --migrate "$REPO"
is "no-CI repo gets two groups" "$(names)" '["branch-safety","pr-flow"]'

echo "selftest: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
