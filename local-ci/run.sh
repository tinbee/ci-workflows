#!/usr/bin/env bash
# local-ci: CI's checks, then a cold-context Claude review, on one commit, each in a throwaway
# container, before it is pushed. GitHub CI still runs on the push and stays the merge gate;
# this exists so review rounds happen before CI instead of each waiting on a CI run.
#
# A repo runs it through its scripts/local-ci.sh, which extracts local-ci/, review/,
# review-rules/ and go-ci.yml from tinbee/ci-workflows at v1 and sets LOCAL_CI_SHARED to
# that directory. The repo's own part is .local-ci.yml (local-ci/README.md).
#
#   run.sh [--base <ref>] [<commit>]   checks + review (default: HEAD against origin/main)
#   run.sh accept <commit> <reason>    pass a fail-review commit whose findings you judged wrong
#   run.sh pre-push <remote> <url>     the pre-push hook (git's ref lines on stdin)
#   run.sh install-hook                install that hook in this repository
#
# Exit: 0 pass, 1 checks failed, 2 blocking findings, 3 could not run.
# Result: <git common dir>/local-ci/<sha>/result.json.
#
# What each container can reach:
#   checks  the commit; go-ci's steps as the commit's own ci.yml configures them; the
#           .local-ci.yml services, on an --internal network; the Go modules, pre-fetched on
#           the host into a read-only file proxy checked against go.sum; and, through a
#           proxy, only the hosts in checks-allow.txt (buf.build, vuln.go.dev). No credential.
#   review  the commit, its diff, the shared rules and the Claude token; Read, Glob and Grep
#           only; through a proxy, only api.anthropic.com. The token never enters the
#           container that runs the commit's code.
#
# Env: LOCAL_CI_CLAUDE_TOKEN (required): a `claude setup-token` token. It reaches the review
#        container as CLAUDE_CODE_OAUTH_TOKEN; never export it on the host under that name,
#        where it would replace the login of every interactive `claude`.
#      LOCAL_CI_MODEL (opus), LOCAL_CI_EFFORT (high): the review's model, as the label's.
#      LOCAL_CI_GOMODCACHE (~/.cache/local-ci/gomod): where the host pre-fetches modules.
set -Eeuo pipefail
# Any unplanned failure is "could not run". Without this, `set -e` exits with the failing
# command's own status, and a 1 or 2 would read as "checks failed" or "blocking findings".
trap 'echo "local-ci: failed at run.sh line $LINENO" >&2; exit 3' ERR

die() {
  echo "local-ci: $*" >&2
  exit 3
}

results="$(cd "$(git rev-parse --git-common-dir)" && pwd)/local-ci"

cmd=run
case "${1:-}" in
  run | accept | pre-push | install-hook) cmd="$1"; shift ;;
esac

# --- accept: the local equivalent of replying to a review thread and resolving it -------------
if [ "$cmd" = accept ]; then
  [ $# -eq 2 ] || die "usage: accept <commit> <reason>"
  sha="$(git rev-parse --verify "$1^{commit}")"
  f="$results/$sha/result.json"
  [ -f "$f" ] || die "no result for $sha; run the checks first"
  # Only a review that ran and found something can be overridden. A failed check is not a
  # judgement call, and an `error` means no review ran: there is no finding to disagree with.
  status="$(jq -r .status "$f")"
  [ "$status" = fail-review ] || die "$sha is '$status'; only a fail-review result can be accepted"
  jq --arg r "$2" --arg at "$(date -u +%FT%TZ)" \
    '.status = "accepted" | .accepted = {reason: $r, at: $at}' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  echo "local-ci: $sha accepted"
  exit 0
fi

# --- pre-push: refuse a branch whose tip has not passed (or been accepted) --------------------
if [ "$cmd" = pre-push ]; then
  main="refs/remotes/${1:-origin}/main"
  blocked=0
  while read -r _local_ref local_sha remote_ref _remote_sha; do
    # Keyed on what lands on the remote, not the local name: `git push origin HEAD` reports
    # the local ref as `HEAD`, and a push by SHA reports the SHA itself.
    case "$remote_ref" in refs/heads/*) ;; *) continue ;; esac
    # A deletion pushes the all-zero id.
    if [ -z "${local_sha//0/}" ]; then continue; fi
    # Already on main: nothing new to review.
    if git merge-base --is-ancestor "$local_sha" "$main" 2>/dev/null; then continue; fi
    branch="${remote_ref#refs/heads/}"
    status="$(jq -r '.status' "$results/$local_sha/result.json" 2>/dev/null)" || status=""
    case "$status" in
      pass | accepted) ;;
      "")
        echo "local-ci: $branch (${local_sha:0:12}) has no local-ci result. Run: make local-ci" >&2
        blocked=1
        ;;
      *)
        echo "local-ci: $branch (${local_sha:0:12}) is '$status'. See $results/$local_sha/result.json" >&2
        blocked=1
        ;;
    esac
  done
  exit "$blocked"
fi

# --- install-hook: a shim that runs the PUSHING worktree's own scripts/local-ci.sh ------------
if [ "$cmd" = install-hook ]; then
  hooks="$(git rev-parse --git-path hooks)"
  mkdir -p "$hooks"
  hook="$(cd "$hooks" && pwd)/pre-push"
  # A repo that sets core.hooksPath to a directory in its own tree (instastack's .githooks)
  # versions its hooks: the shim belongs there as a committed file, not written by this.
  case "$hook" in
    "$(git rev-parse --show-toplevel)"/*)
      die "this repo keeps its hooks in $(dirname "$hook") (core.hooksPath); commit a pre-push there that runs: exec \"\$(git rev-parse --show-toplevel)/scripts/local-ci.sh\" pre-push \"\$@\""
      ;;
  esac
  mkdir -p "$(dirname "$hook")"
  # rm first: writing through an existing symlink would overwrite the file it points at.
  rm -f "$hook"
  cat > "$hook" <<'EOF'
#!/bin/sh
# Installed by local-ci install-hook (tinbee/ci-workflows local-ci/run.sh). Runs the pushing
# worktree's own scripts/local-ci.sh, so removing a worktree cannot leave it dangling.
h="$(git rev-parse --show-toplevel)/scripts/local-ci.sh"
if [ ! -x "$h" ]; then
  echo "local-ci: this branch has no scripts/local-ci.sh, so the push is not checked" >&2
  exit 0
fi
exec "$h" pre-push "$@"
EOF
  chmod +x "$hook"
  echo "local-ci: pre-push installed at $hook"
  exit 0
fi

# --- run ---------------------------------------------------------------------------------------
[ -n "${LOCAL_CI_SHARED:-}" ] || die "run this through the repo's scripts/local-ci.sh, which sets LOCAL_CI_SHARED"
shared="$LOCAL_CI_SHARED"
MODEL="${LOCAL_CI_MODEL:-opus}"
EFFORT="${LOCAL_CI_EFFORT:-high}"
GOMODCACHE_HOST="${LOCAL_CI_GOMODCACHE:-$HOME/.cache/local-ci/gomod}"
repo_name="$(basename -s .git "$(git remote get-url origin 2>/dev/null || git rev-parse --show-toplevel)")"

base_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base_ref="${2:?--base needs a ref}"; shift 2 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
sha="$(git rev-parse --verify "${1:-HEAD}^{commit}")" || die "not a commit: ${1:-HEAD}"

for tool in docker jq yq; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
docker info >/dev/null 2>&1 || die "docker is not running"

if [ -z "$base_ref" ]; then
  git fetch -q origin main 2>/dev/null \
    || echo "local-ci: could not fetch origin/main; diffing against the local copy" >&2
  base_ref=origin/main
fi
base="$(git merge-base "$base_ref" "$sha")" || die "no merge base between $base_ref and $sha"
[ "$base" != "$sha" ] || die "$sha is already on $base_ref, so there is nothing to review (--base <ref> reviews a range)"

if [ "$sha" = "$(git rev-parse HEAD)" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "local-ci: uncommitted changes are not part of ${sha:0:12} and are not checked" >&2
fi

# Fail before the checks, not after them, when the review could never run.
[ -n "${LOCAL_CI_CLAUDE_TOKEN:-}" ] || die "LOCAL_CI_CLAUDE_TOKEN is not set (a 'claude setup-token' token; op-secrets loads it)"

# --- what to run: the commit's own .local-ci.yml and ci.yml, go-ci.yml's defaults at v1 -------
cfg="$(git show "$sha:.local-ci.yml" 2>/dev/null)" || die "no .local-ci.yml at ${sha:0:12} (local-ci/README.md)"
ci_yml="$(git show "$sha:.github/workflows/ci.yml" 2>/dev/null)" || die "no .github/workflows/ci.yml at ${sha:0:12}"
job="$(yq -r '.ci_job // ""' <<<"$cfg")"
if [ -z "$job" ]; then
  job="$(yq -r '.jobs | to_entries[] | select((.value.uses // "") | test("/go-ci\.yml@")) | .key' <<<"$ci_yml" | head -1)"
fi
[ -n "$job" ] || die "ci.yml at ${sha:0:12} has no job calling go-ci.yml (set ci_job in .local-ci.yml)"
case "$(yq -r ".jobs.\"$job\".uses // \"\"" <<<"$ci_yml")" in
  */go-ci.yml@*) ;;
  *) die "ci.yml job '$job' does not call go-ci.yml" ;;
esac

# The caller's `with` over go-ci.yml's own defaults, so a default changed at v1 is the
# default here too.
defaults="$(yq -o json '.on.workflow_call.inputs | map_values(.default)' "$shared/.github/workflows/go-ci.yml")"
with="$(yq -o json ".jobs.\"$job\".with // {}" <<<"$ci_yml")"
if jq -e 'to_entries | any(.value | tostring | contains("${{"))' <<<"$with" >/dev/null; then
  die "ci.yml job '$job' passes a \${{ }} expression to go-ci, which this cannot evaluate: $(jq -c 'to_entries | map(select(.value | tostring | contains("${{"))) | from_entries' <<<"$with")"
fi
after="$(yq -r '.after // ""' <<<"$cfg")"
inputs="$(jq -n --argjson d "$defaults" --argjson w "$with" --arg after "$after" '$d + $w + {after: $after}')"
input() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<<"$inputs"; }

wd="$(input working_directory)"
wd="${wd:-.}"
go_version="$(git show "$sha:$wd/$(input go_version_file)" | awk '$1 == "go" { print $2; exit }')"
[ -n "$go_version" ] || die "no go line in $wd/$(input go_version_file) at ${sha:0:12}"

out="$results/$sha"
mkdir -p "$out"
work="$(mktemp -d)"
ns="local-ci-$repo_name-$$"
cleanup() {
  docker ps -aq --filter "label=local-ci.run=$ns" | xargs docker rm -f >/dev/null 2>&1 || true
  docker network rm "$ns" "$ns-review" >/dev/null 2>&1 || true
  git update-ref -d "refs/local-ci/$ns/head" 2>/dev/null || true
  git update-ref -d "refs/local-ci/$ns/base" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

write_result() { # <status> <checks exit> <review json or null> <envelope json or null>
  jq -n --arg sha "$sha" --arg base "$base" --arg status "$1" --argjson checks_exit "$2" \
    --argjson review "$3" --argjson envelope "$4" --arg model "$MODEL" --arg effort "$EFFORT" \
    --arg at "$(date -u +%FT%TZ)" --argjson checks_s "${checks_s:-0}" --argjson review_s "${review_s:-0}" \
    '{sha: $sha, base: $base, status: $status, created: $at,
      seconds: {checks: $checks_s, review: $review_s},
      checks: {exit: $checks_exit},
      review: (if $review == null then null else $review + {
        model: $model, effort: $effort,
        turns: $envelope.num_turns, cost_usd: $envelope.total_cost_usd} end)}' \
    > "$out/result.json"
}

# --- inputs: the commit as a bundle, plus what each container needs beside it -----------------
mkdir -p "$work/checks" "$work/review"
# A bundle carries refs, not bare SHAs, so the commit and its base get short-lived refs.
git update-ref "refs/local-ci/$ns/head" "$sha"
git update-ref "refs/local-ci/$ns/base" "$base"
git bundle create -q "$work/checks/repo.bundle" "refs/local-ci/$ns/head" "refs/local-ci/$ns/base" \
  || die "could not bundle $sha"
cp "$work/checks/repo.bundle" "$work/review/repo.bundle"
printf '%s\n' "$inputs" > "$work/checks/inputs.json"
cp -R "$shared/review-rules" "$work/review/"
git show "$sha:.github/workflows/claude-review.yml" 2>/dev/null \
  | yq -r '.jobs."claude-review".with.project_context // ""' > "$work/review/project_context.txt" 2>/dev/null \
  || : > "$work/review/project_context.txt"

# Modules: a vendored repo needs none. Otherwise the HOST downloads them, with its own
# credentials for private ones (goprivate), into a cache the checks container sees only as a
# read-only GOPROXY=file:// tree. Go checks every module against the commit's go.sum, so the
# container can neither fetch anything else nor reach a credential. `go mod download` runs no
# module code.
module_flags=()
if ! git cat-file -e "$sha:$wd/vendor/modules.txt" 2>/dev/null; then
  command -v go >/dev/null || die "go is not installed on the host, and ${sha:0:12} is not vendored"
  mkdir -p "$work/src" "$GOMODCACHE_HOST"
  git archive "$sha" | tar -x -C "$work/src"
  goprivate="$(input goprivate)"
  echo "local-ci: fetching modules on the host into $GOMODCACHE_HOST" >&2
  (cd "$work/src/$wd" && GOMODCACHE="$GOMODCACHE_HOST" GOWORK=off GOFLAGS=-mod=mod \
    GOPRIVATE="${goprivate:-${GOPRIVATE:-}}" go mod download) > "$out/modules.log" 2>&1 \
    || { tail -20 "$out/modules.log" >&2; die "could not download ${sha:0:12}'s modules on the host (log: $out/modules.log)"; }
  module_flags=(-v "$GOMODCACHE_HOST/cache/download:/goproxy:ro"
    -e GOPROXY=file:///goproxy -e GOSUMDB=off -e GOFLAGS=-mod=mod -e GOPRIVATE= -e GONOSUMDB=)
fi

checks_image="local-ci-checks:go$go_version-buf$(input buf)-sqlc$(input sqlc_version)-golangci$(input golangci_version)-vuln$(input govulncheck)"
echo "local-ci: building images (Go $go_version)" >&2
docker build -q --build-arg GO_VERSION="$go_version" --build-arg BUF="$(input buf)" \
  --build-arg SQLC_VERSION="$(input sqlc_version)" --build-arg GOLANGCI_VERSION="$(input golangci_version)" \
  --build-arg GOVULNCHECK="$(input govulncheck)" -t "$checks_image" \
  -f "$shared/local-ci/checks.Dockerfile" "$shared/local-ci" >/dev/null \
  || die "could not build the checks image for Go $go_version"
docker build -q -t local-ci-review -f "$shared/review/local/review.Dockerfile" "$shared/review" >/dev/null \
  || die "could not build the review image"
docker build -q -t local-ci-proxy -f "$shared/review/local/proxy.Dockerfile" "$shared/review" >/dev/null \
  || die "could not build the proxy image"

start_proxy() { # <network> <name> <allow file>: the only way out of an --internal network
  docker run -d --label "local-ci.run=$ns" --name "$2" --network "$1" --network-alias proxy \
    -v "$3:/etc/tinyproxy/allow:ro" local-ci-proxy >/dev/null
  docker network connect bridge "$2"
  local _
  for _ in $(seq 1 20); do
    if docker exec "$2" nc -z 127.0.0.1 8888 >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  die "the egress proxy $2 did not start"
}

# --- checks -----------------------------------------------------------------------------------
echo "local-ci: checks on ${sha:0:12}: ci.yml job '$job' (go-ci.yml), then ${after:-no after script} (log: $out/checks.log)" >&2
t0=$SECONDS
docker network create --internal "$ns" >/dev/null
start_proxy "$ns" "$ns-proxy" "$shared/local-ci/checks-allow.txt"

no_proxy=localhost,127.0.0.1
while IFS=$'\t' read -r name image; do
  [ -n "$name" ] || continue
  env_flags=()
  while IFS= read -r kv; do
    [ -n "$kv" ] && env_flags+=(-e "$kv")
  done < <(yq -r ".services.\"$name\".env // {} | to_entries[] | \"\(.key)=\(.value)\"" <<<"$cfg")
  docker run -d --label "local-ci.run=$ns" --name "$ns-$name" --network "$ns" --network-alias "$name" \
    ${env_flags[@]+"${env_flags[@]}"} "$image" >/dev/null
  no_proxy="$no_proxy,$name"
  ready="$(yq -r ".services.\"$name\".ready // \"\"" <<<"$cfg")"
  if [ -n "$ready" ]; then
    ok=""
    for _ in $(seq 1 60); do
      if docker exec "$ns-$name" sh -c "$ready" >/dev/null 2>&1; then ok=1; break; fi
      sleep 1
    done
    [ -n "$ok" ] || die "service $name did not become ready in 60s ($ready)"
  fi
done < <(yq -r '.services // {} | to_entries[] | "\(.key)\t\(.value.image)"' <<<"$cfg")

env_flags=()
while IFS= read -r kv; do
  [ -n "$kv" ] && env_flags+=(-e "$kv")
done < <(yq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' <<<"$cfg")

# In an `if`, so a failing check is a result here rather than an ERR.
if tar -C "$work/checks" -cf - . | docker run --rm -i --label "local-ci.run=$ns" --network "$ns" \
  -e SHA="$sha" -e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888 -e NO_PROXY="$no_proxy" \
  ${module_flags[@]+"${module_flags[@]}"} ${env_flags[@]+"${env_flags[@]}"} \
  -v "local-ci-gocache-$repo_name:/home/ci/.cache/go-build" \
  "$checks_image" > "$out/checks.log" 2>&1; then
  checks_exit=0
else
  checks_exit=$?
fi
checks_s=$((SECONDS - t0))
docker logs "$ns-proxy" > "$out/checks-proxy.log" 2>&1 || true
docker ps -aq --filter "label=local-ci.run=$ns" | xargs docker rm -f >/dev/null 2>&1 || true

if [ "$checks_exit" -ne 0 ]; then
  write_result fail-checks "$checks_exit" null null
  tail -40 "$out/checks.log" >&2
  echo "local-ci: checks FAILED (exit $checks_exit, ${checks_s}s); no review of code that fails CI" >&2
  exit 1
fi
echo "local-ci: checks passed (${checks_s}s)" >&2

# --- review -----------------------------------------------------------------------------------
echo "local-ci: review of ${base:0:12}...${sha:0:12} with $MODEL ($EFFORT) (log: $out/review.log)" >&2
t0=$SECONDS
docker network create --internal "$ns-review" >/dev/null
start_proxy "$ns-review" "$ns-review-proxy" "$shared/review/local/proxy-allow.txt"

# NONESSENTIAL_TRAFFIC off: telemetry and update checks would only be refused at the proxy.
if tar -C "$work/review" -cf - . | CLAUDE_CODE_OAUTH_TOKEN="$LOCAL_CI_CLAUDE_TOKEN" docker run --rm -i \
  --label "local-ci.run=$ns" --network "$ns-review" \
  -e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888 \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e CLAUDE_CODE_OAUTH_TOKEN -e SHA="$sha" -e BASE="$base" -e MODEL="$MODEL" -e EFFORT="$EFFORT" \
  local-ci-review > "$out/review.raw.json" 2> "$out/review.log"; then
  review_exit=0
else
  review_exit=$?
fi
review_s=$((SECONDS - t0))
# Kept beside the result: a refused host is the first thing to look for when a review fails.
docker logs "$ns-review-proxy" > "$out/proxy.log" 2>&1 || true

envelope="$(jq -c . "$out/review.raw.json" 2>/dev/null)" || envelope=null
review="$(jq -ce '.structured_output // (.result | fromjson?) // empty' "$out/review.raw.json" 2>/dev/null)" || review=""
if [ "$review_exit" -ne 0 ] || [ -z "$review" ] || ! jq -e '.findings | type == "array"' <<<"$review" >/dev/null; then
  write_result error 0 null "${envelope:-null}"
  tail -20 "$out/review.log" >&2
  die "the review produced no findings list (exit $review_exit); see $out/review.raw.json"
fi

blocking="$(jq '[.findings[] | select(.severity == "blocking")] | length' <<<"$review")"
if [ "$blocking" -eq 0 ]; then status=pass; else status=fail-review; fi
write_result "$status" 0 "$review" "$envelope"

jq -r '.findings[] | "  [\(.severity)] \(.file):\(.line)  \(.summary)"' <<<"$review" >&2
jq -r '.summary' <<<"$review" >&2
echo "local-ci: $status (checks ${checks_s}s, review ${review_s}s; $out/result.json)" >&2
[ "$status" = pass ] || exit 2
