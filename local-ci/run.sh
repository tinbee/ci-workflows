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
#   checks  the commit; go-ci's steps as the commit's own ci.yml configures them, one
#           container per ci.yml job; that job's .local-ci.yml services, on its own
#           --internal network; the Go modules (every module in the commit, and each
#           `go run tool@version` in ci.yml), pre-fetched on the host into a read-only file
#           proxy; and, through a proxy, only the hosts in checks-allow.txt (buf.build,
#           vuln.go.dev). No credential.
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

# macOS tar writes an AppleDouble `._name` beside every file with extended attributes, and a
# checkout has them (com.apple.provenance). In the container they are real files: buf tried to
# compile `._agent.proto`. This stops tar writing them; elsewhere it is ignored.
export COPYFILE_DISABLE=1

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
  # Inside the git dir (the usual .git/hooks) is not that case, though .git is in the tree.
  gitdir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
  case "$hook" in
    "$gitdir"/*) ;;
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
# Both files come from the commit, which is untrusted. Each is parsed ONCE with a fixed yq
# expression; every lookup after that is jq with the commit's strings passed as --arg data,
# never spliced into an expression (yq has load() and env(): a crafted job name could read
# host files into the inputs the commit's code is given). Every value that then reaches a
# shell, a docker flag or a path must match a pattern first.
cfg="$(git show "$sha:.local-ci.yml" 2>/dev/null | yq -o json '.')" \
  || die "no readable .local-ci.yml at ${sha:0:12} (local-ci/README.md)"
ci="$(git show "$sha:.github/workflows/ci.yml" 2>/dev/null | yq -o json '.')" \
  || die "no readable .github/workflows/ci.yml at ${sha:0:12}"
must_match() { # <what> <value> <extended regex>
  [[ "$2" =~ $3 ]] || die "$1 '$2' is not of the form $3"
}
must_be_relative_path() { # <what> <value>: inside the tree, no `..`
  must_match "$1" "$2" '^[A-Za-z0-9_.][A-Za-z0-9_./-]*$'
  case "/$2/" in */../*) die "$1 '$2' leaves the repository" ;; esac
}
name_re='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

# The caller's `with` over go-ci.yml's own defaults, so a default changed at v1 is the
# default here too.
defaults="$(yq -o json '.on.workflow_call.inputs | map_values(.default)' "$shared/.github/workflows/go-ci.yml")"
# Not `.[$k] // ""`: jq's `//` treats false as missing, so go-ci's `buf: false` came back "".
# Reads the job being planned or run.
input() { jq -r --arg k "$1" '.[$k] | if . == null then "" else tostring end' <<<"$inputs"; }

# plan: the jobs that run here, in ci.yml's order, each with its go-ci inputs and its own part
# of .local-ci.yml. skipped: {job: reason} for the ones .local-ci.yml says stay CI-only.
plan="[]"
skipped="{}"

plan_go_job() { # <ci.yml job> <its .local-ci.yml settings, as JSON>
  local job="$1" jcfg="$2" with after wd go_version
  with="$(jq -c --arg j "$job" '.jobs[$j].with // {}' <<<"$ci")"
  if jq -e 'to_entries | any(.value | tostring | contains("${{"))' <<<"$with" >/dev/null; then
    die "ci.yml job '$job' passes a \${{ }} expression to go-ci, which this cannot evaluate: $(jq -c 'to_entries | map(select(.value | tostring | contains("${{"))) | from_entries' <<<"$with")"
  fi
  after="$(jq -r '.after // ""' <<<"$jcfg")"
  [ -z "$after" ] || must_be_relative_path "after" "$after"
  inputs="$(jq -c -n --argjson d "$defaults" --argjson w "$with" --arg after "$after" '$d + $w + {after: $after}')"

  # These reach a Dockerfile's RUN lines (as build args), an image tag and git paths.
  must_match "buf" "$(input buf)" '^(true|false)$'
  must_match "govulncheck" "$(input govulncheck)" '^(true|false)$'
  must_match "sqlc_version" "$(input sqlc_version)" '^([0-9]+\.[0-9]+\.[0-9]+)?$'
  must_match "golangci_version" "$(input golangci_version)" '^(v[0-9]+(\.[0-9]+){0,2})?$'
  wd="$(input working_directory)"
  wd="${wd:-.}"
  must_be_relative_path "working_directory" "$wd"
  must_be_relative_path "go_version_file" "$(input go_version_file)"
  go_version="$(git show "$sha:$wd/$(input go_version_file)" | awk '$1 == "go" { print $2; exit }')"
  [ -n "$go_version" ] || die "no go line in $wd/$(input go_version_file) at ${sha:0:12}"
  must_match "go version" "$go_version" '^[0-9]+\.[0-9]+(\.[0-9]+)?((rc|beta)[0-9]+)?$'

  plan="$(jq -c --arg n "$job" --argjson c "$jcfg" --argjson i "$inputs" --arg wd "$wd" --arg g "$go_version" \
    '. + [{name: $n, cfg: $c, inputs: $i, wd: $wd, go_version: $g}]' <<<"$plan")"
}

if jq -e 'has("jobs")' <<<"$cfg" >/dev/null; then
  # `jobs:` names EVERY ci.yml job, as a mirror or as `skip: <reason>`, so a pass says which
  # required checks it stands for. A job ci.yml gains is a stop here until it is listed.
  jq -e '.jobs | type == "object" and length > 0' <<<"$cfg" >/dev/null \
    || die ".local-ci.yml jobs: must map ci.yml job names to their settings"
  for k in ci_job services env after; do
    if jq -e --arg k "$k" 'has($k)' <<<"$cfg" >/dev/null; then
      die ".local-ci.yml has jobs: and a top-level $k; with jobs:, $k goes under its job"
    fi
  done
  ci_jobs="$(jq -r '.jobs // {} | keys_unsorted[]' <<<"$ci")"
  [ -n "$ci_jobs" ] || die "ci.yml at ${sha:0:12} has no jobs"
  stale="$(jq -r --argjson ci "$ci" '.jobs | keys - ($ci.jobs | keys) | join(", ")' <<<"$cfg")"
  [ -z "$stale" ] || die ".local-ci.yml jobs: names $stale, which ci.yml at ${sha:0:12} does not have"
  while IFS= read -r job; do
    # It names containers, networks and log sections.
    must_match "ci.yml job" "$job" "$name_re"
    jq -e --arg j "$job" '.jobs | has($j)' <<<"$cfg" >/dev/null \
      || die "ci.yml job '$job' is not in .local-ci.yml jobs: (settings, {} for none, or skip: <reason>)"
    # `go:` with nothing after it is null: no settings.
    jcfg="$(jq -c --arg j "$job" '.jobs[$j] // {}' <<<"$cfg")"
    jq -e 'type == "object"' <<<"$jcfg" >/dev/null || die "jobs.$job must be a map"
    unknown="$(jq -r 'keys - ["after", "env", "services", "skip"] | join(", ")' <<<"$jcfg")"
    [ -z "$unknown" ] || die "jobs.$job: unknown key(s) $unknown"
    if jq -e 'has("skip")' <<<"$jcfg" >/dev/null; then
      reason="$(jq -r '.skip | strings' <<<"$jcfg")"
      [ -n "$reason" ] || die "jobs.$job: skip needs a reason"
      [ "$(jq length <<<"$jcfg")" -eq 1 ] || die "jobs.$job is skipped, so it takes no other settings"
      skipped="$(jq -c --arg n "$job" --arg r "$reason" '. + {($n): $r}' <<<"$skipped")"
      continue
    fi
    uses="$(jq -r --arg j "$job" '.jobs[$j].uses // ""' <<<"$ci")"
    case "$uses" in
      */go-ci.yml@*) plan_go_job "$job" "$jcfg" ;;
      "") die "ci.yml job '$job' is inline, and local-ci cannot run it yet (skip: <reason>)" ;;
      *) die "ci.yml job '$job' calls $uses, which local-ci cannot run yet (skip: <reason>)" ;;
    esac
  done <<<"$ci_jobs"
  [ "$(jq length <<<"$plan")" -gt 0 ] || die "every ci.yml job is skipped, so there is nothing to check"
else
  # The first shape: one go-ci job, its settings at the top level, other jobs unchecked.
  job="$(jq -r '.ci_job // ""' <<<"$cfg")"
  if [ -z "$job" ]; then
    job="$(jq -r '.jobs | to_entries[] | select((.value.uses // "") | test("/go-ci\\.yml@")) | .key' <<<"$ci" | head -1)"
  fi
  [ -n "$job" ] || die "ci.yml at ${sha:0:12} has no job calling go-ci.yml (set ci_job in .local-ci.yml)"
  must_match "ci_job" "$job" "$name_re"
  case "$(jq -r --arg j "$job" '.jobs[$j].uses // ""' <<<"$ci")" in
    */go-ci.yml@*) ;;
    *) die "ci.yml job '$job' does not call go-ci.yml" ;;
  esac
  plan_go_job "$job" "$(jq -c '{after, env, services} | with_entries(select(.value != null))' <<<"$cfg")"
fi

out="$results/$sha"
mkdir -p "$out"
work="$(mktemp -d)"
ns="local-ci-$repo_name-$$"
started="$(date -u +%FT%TZ)"

# state.json, beside the result: where this run is, for anything watching runs live (confleet's
# Local CI page). `pid` and `ns` (the label on every container this run starts) are what a
# cancel needs: TERM to the pid, `docker rm -f` by label. `job`, during the checks, is the
# ci.yml job whose modules, image or checks the phase is. Written whole, via a rename.
job=""
state() { # <phase> [<exit code>]
  jq -n --arg sha "$sha" --arg base "$base" --arg phase "$1" --argjson pid "$$" --arg ns "$ns" \
    --arg started "$started" --arg at "$(date -u +%FT%TZ)" --arg exit "${2:-}" --arg job "$job" \
    '{sha: $sha, base: $base, pid: $pid, ns: $ns, phase: $phase, started: $started, updated: $at}
     + (if $job == "" then {} else {job: $job} end)
     + (if $exit == "" then {} else {exit: ($exit | tonumber), finished: $at} end)' \
    > "$out/state.json.tmp" && mv "$out/state.json.tmp" "$out/state.json"
}

cleanup() {
  local rc=$?
  job=""
  state "done" "$rc" 2>/dev/null || true
  docker ps -aq --filter "label=local-ci.run=$ns" | xargs docker rm -f >/dev/null 2>&1 || true
  docker network ls -q --filter "label=local-ci.run=$ns" | xargs docker network rm >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# A cancel is a TERM. Bash defers it while a foreground command runs, so a cancel also removes
# this run's containers, which ends that command; then this exits and cleanup records it.
trap 'exit 143' TERM
trap 'exit 130' INT
state preparing

# checks.exit and seconds.checks are the whole of the checks; checks.jobs has each ci.yml job
# as {exit, seconds}, or {skipped: reason}. A job after a failed one is absent: it did not run.
checks_jobs="$(jq -c 'map_values({skipped: .})' <<<"$skipped")"
write_result() { # <status> <checks exit> <review json or null> <envelope json or null>
  jq -n --arg sha "$sha" --arg base "$base" --arg status "$1" --argjson checks_exit "$2" \
    --argjson review "$3" --argjson envelope "$4" --arg model "$MODEL" --arg effort "$EFFORT" \
    --arg at "$(date -u +%FT%TZ)" --argjson checks_s "${checks_s:-0}" --argjson review_s "${review_s:-0}" \
    --argjson jobs "$checks_jobs" \
    '{sha: $sha, base: $base, status: $status, created: $at,
      seconds: {checks: $checks_s, review: $review_s},
      checks: {exit: $checks_exit, jobs: $jobs},
      review: (if $review == null then null else $review + {
        model: $model, effort: $effort,
        turns: $envelope.num_turns, cost_usd: $envelope.total_cost_usd} end)}' \
    > "$out/result.json"
}

# --- inputs: the commit's files and diff, plus what each container needs beside them ----------
# By tree, not by history: a shallow clone (instastack's is) cannot bundle a commit whose
# parents it lacks. read-tree + checkout-index run no hooks and, unlike `git archive`, drop
# nothing marked export-ignore.
export_tree() { # <commit> <dir>
  local idx="$work/index"
  GIT_INDEX_FILE="$idx" git read-tree "$1"
  GIT_INDEX_FILE="$idx" git checkout-index -a -f --prefix="$2/"
  rm -f "$idx"
}
mkdir -p "$work/review"
export_tree "$sha" "$work/tree" || die "could not export the files of $sha"
cp -R "$work/tree" "$work/review/tree"
git diff "$base" "$sha" > "$work/review/pr.diff"
git diff --name-only "$base" "$sha" > "$work/review/files.txt"
cp -R "$shared/review-rules" "$work/review/"
git show "$sha:.github/workflows/claude-review.yml" 2>/dev/null \
  | yq -r '.jobs."claude-review".with.project_context // ""' > "$work/review/project_context.txt" 2>/dev/null \
  || : > "$work/review/project_context.txt"

state images
docker build -q -t local-ci-review -f "$shared/review/local/review.Dockerfile" "$shared/review" >/dev/null \
  || die "could not build the review image"
docker build -q -t local-ci-proxy -f "$shared/review/local/proxy.Dockerfile" "$shared/review" >/dev/null \
  || die "could not build the proxy image"

start_proxy() { # <network> <name> <allow file> [<job>]: the only way out of an --internal network
  docker run -d --label "local-ci.run=$ns" --label "local-ci.job=${4:-}" --name "$2" --network "$1" \
    --network-alias proxy -v "$3:/etc/tinyproxy/allow:ro" local-ci-proxy >/dev/null
  docker network connect bridge "$2"
  local _
  for _ in $(seq 1 20); do
    if docker exec "$2" nc -z 127.0.0.1 8888 >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  die "the egress proxy $2 did not start"
}

# .local-ci.yml env as `docker run -e` flags, into env_flags. Split on lines, a
# value `"x\nLOCAL_CI_CLAUDE_TOKEN"` became a bare `-e LOCAL_CI_CLAUDE_TOKEN`, which docker
# fills from THIS shell's environment: the token, into the container that runs the commit.
# So jq itself refuses a key that is not a name and a value with a newline, CR or NUL, and
# emits NUL-separated pairs; they go through a file so a jq refusal stops the run rather
# than ending a loop early. Every pair must still contain `=`.
env_flags_from() { # <JSON object, or null>
  local kv file="$work/env-pairs"
  env_flags=()
  jq -j '. // {} | to_entries[]
    | if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
         and ((.value | tostring) | test("[\n\r\u0000]") | not)
      then "\(.key)=\(.value | tostring)\u0000"
      else error("env \(.key | tojson): must be a NAME with a value on one line")
      end' <<<"$1" > "$file" || die ".local-ci.yml: an env entry is not NAME: one-line value"
  while IFS= read -r -d '' kv; do
    [[ "$kv" == *=* ]] || die ".local-ci.yml: env entry without '=': $kv"
    env_flags+=(-e "$kv")
  done < "$file"
}

# Modules: the HOST downloads them, with its own credentials for private ones, into a cache the
# checks container sees only as a read-only GOPROXY=file:// tree. The container has no other
# way to a module, so it can neither fetch anything else nor reach a credential, and a module
# the host did not fetch fails the run. Downloading runs no module code, and the commit decides
# none of how it happens:
#   GOPRIVATE  the host's own, never ci.yml's goprivate: `*` there would send every fetch,
#              vanity paths included, straight to VCS with the host's git credentials.
#   GOVCS      private modules by git only, public ones only through the module proxy.
#   GOTOOLCHAIN=local  go.mod's `toolchain` line cannot download and run another Go here.
#
# What is fetched: every module in the commit (a go.mod outside testdata/, vendor/ and the
# directories Go skips, `.x` and `_x`), unless vendored; and every `go run|install
# <path>@<version>` in this job's go-ci commands and `after` script, resolved with `go get` in
# a throwaway module, which downloads what the tool's build needs and runs none of it. Not a
# public proxy from the container instead: proxy.golang.org fetches any path it is asked for,
# from wherever that path points, so a commit's code could send data out through it.
in_dir() { # <dir> <path>: <path> inside <dir>, without a leading ./ (which git reads as cwd)
  if [ "$1" = . ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}
host_go_env() { # <command...>: go on the host, fetching into the shared cache
  GOMODCACHE="$GOMODCACHE_HOST" GOWORK=off GOFLAGS=-mod=mod GOPRIVATE="$host_goprivate" \
    GONOPROXY='' GONOSUMDB='' GOINSECURE='' GOVCS='private:git,public:off' GOTOOLCHAIN=local "$@"
}
fetch_modules() { # for the job in $wd and $inputs; sets module_flags
  local host_goprivate mods=() tools=() m k tool dir
  module_flags=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    dir="$(dirname "$m")"
    case "/$dir/" in */testdata/* | */vendor/* | */.[!/]*/* | */_*/*) continue ;; esac
    if git cat-file -e "$sha:$(in_dir "$dir" vendor/modules.txt)" 2>/dev/null; then continue; fi
    must_be_relative_path "module directory" "$dir"
    mods+=("$dir")
  done < <(git ls-tree -r --name-only "$sha" | grep -E '(^|/)go\.mod$' || true)
  {
    for k in generate_command lint_command build_command test_command post_command; do input "$k"; done
    [ -z "$(input after)" ] || git show "$sha:$(input after)" 2>/dev/null || true
  } > "$work/commands.txt"
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    # An exact version, so the container can resolve it from the cache with no listing.
    must_match "go run/install target" "$tool" '^[A-Za-z0-9][A-Za-z0-9._~/-]*@v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.+-]*)?$'
    tools+=("$tool")
  done < <(grep -oE 'go +(run|install) +[^[:space:]-][^[:space:]]*@[^[:space:]);&|"'"'"']+' "$work/commands.txt" \
    | awk '{ print $NF }' | sort -u || true)
  [ ${#mods[@]} -gt 0 ] || [ ${#tools[@]} -gt 0 ] || return 0

  command -v go >/dev/null || die "go is not installed on the host, which fetches ${sha:0:12}'s modules"
  mkdir -p "$GOMODCACHE_HOST"
  host_goprivate="$(go env GOPRIVATE)"
  if [ -n "$(input goprivate)" ] && [ "$(input goprivate)" != "$host_goprivate" ]; then
    echo "local-ci: ci.yml's goprivate is '$(input goprivate)'; fetching with this machine's GOPRIVATE '$host_goprivate'" >&2
  fi
  echo "local-ci: fetching on the host into $GOMODCACHE_HOST: modules of ${mods[*]:-nothing}${tools[*]:+; tools ${tools[*]}}" >&2
  for dir in ${mods[@]+"${mods[@]}"}; do
    echo "::: job $job: $dir" >> "$out/modules.log"
    (cd "$work/tree/$dir" && host_go_env go mod download) >> "$out/modules.log" 2>&1 \
      || { tail -20 "$out/modules.log" >&2; die "could not download the modules of $dir on the host (log: $out/modules.log)"; }
  done
  for tool in ${tools[@]+"${tools[@]}"}; do
    echo "::: job $job: $tool" >> "$out/modules.log"
    rm -rf "$work/tool" && mkdir -p "$work/tool"
    (cd "$work/tool" && host_go_env go mod init local-ci-tool && host_go_env go get "$tool") >> "$out/modules.log" 2>&1 \
      || { tail -20 "$out/modules.log" >&2; die "could not download $tool on the host (log: $out/modules.log)"; }
  done
  module_flags=(-v "$GOMODCACHE_HOST/cache/download:/goproxy:ro"
    -e GOPROXY=file:///goproxy -e GOSUMDB=off -e GOPRIVATE= -e GONOSUMDB=)
  # -mod=mod for an unvendored job only: in a vendored one it would bypass vendor/.
  if ! git cat-file -e "$sha:$(in_dir "$wd" vendor/modules.txt)" 2>/dev/null; then
    module_flags+=(-e GOFLAGS=-mod=mod)
  fi
}

# One go-ci job, from its plan entry ($job, $jcfg, $inputs, $wd, $go_version): its modules, its
# image, its services on a network of its own, then its checks. Sets job_exit.
run_go_job() {
  local net="$ns-job-$job" name image ready ok after checks_image no_proxy=localhost,127.0.0.1
  after="$(input after)"
  state modules
  fetch_modules

  state images
  checks_image="local-ci-checks:go$go_version-buf$(input buf)-sqlc$(input sqlc_version)-golangci$(input golangci_version)-vuln$(input govulncheck)"
  echo "local-ci: building the checks image for '$job' (Go $go_version)" >&2
  docker build -q --build-arg GO_VERSION="$go_version" --build-arg BUF="$(input buf)" \
    --build-arg SQLC_VERSION="$(input sqlc_version)" --build-arg GOLANGCI_VERSION="$(input golangci_version)" \
    --build-arg GOVULNCHECK="$(input govulncheck)" -t "$checks_image" \
    -f "$shared/local-ci/checks.Dockerfile" "$shared/local-ci" >/dev/null \
    || die "could not build the checks image for Go $go_version"

  state checks
  echo "local-ci: checks on ${sha:0:12}: ci.yml job '$job' (go-ci.yml), then ${after:-no after script} (log: $out/checks.log)" >&2
  mkdir -p "$work/checks-$job"
  cp -R "$work/tree" "$work/checks-$job/tree"
  printf '%s\n' "$inputs" > "$work/checks-$job/inputs.json"
  docker network create --internal --label "local-ci.run=$ns" "$net" >/dev/null
  start_proxy "$net" "$net-proxy" "$shared/local-ci/checks-allow.txt" "$job"

  while IFS=$'\t' read -r name image; do
    [ -n "$name" ] || continue
    must_match "service name" "$name" "$name_re"
    # Positional after the flags, so an image starting with `-` would be read as one.
    must_match "service image" "$image" '^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
    env_flags_from "$(jq -c --arg n "$name" '.services[$n].env' <<<"$jcfg")"
    docker run -d --label "local-ci.run=$ns" --label "local-ci.job=$job" --name "$net-$name" \
      --network "$net" --network-alias "$name" ${env_flags[@]+"${env_flags[@]}"} "$image" >/dev/null
    no_proxy="$no_proxy,$name"
    # Runs in the service's own container, which has no credential and no route out.
    ready="$(jq -r --arg n "$name" '.services[$n].ready // ""' <<<"$jcfg")"
    if [ -n "$ready" ]; then
      ok=""
      for _ in $(seq 1 60); do
        if docker exec "$net-$name" sh -c "$ready" >/dev/null 2>&1; then ok=1; break; fi
        sleep 1
      done
      [ -n "$ok" ] || die "service $name of job $job did not become ready in 60s ($ready)"
    fi
  done < <(jq -r '.services // {} | to_entries[] | "\(.key)\t\(.value.image)"' <<<"$jcfg")

  env_flags_from "$(jq -c '.env' <<<"$jcfg")"

  # No build cache kept between runs: the commit's code can write to it, and Go trusts a cache
  # entry by its key, so one commit could plant a result a later commit's build would use.
  # In an `if`, so a failing check is a result here rather than an ERR.
  echo "::: job $job" >> "$out/checks.log"
  if tar -C "$work/checks-$job" -cf - . | docker run --rm -i --label "local-ci.run=$ns" \
    --label "local-ci.job=$job" --network "$net" \
    -e SHA="$sha" -e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888 -e NO_PROXY="$no_proxy" \
    ${module_flags[@]+"${module_flags[@]}"} ${env_flags[@]+"${env_flags[@]}"} \
    "$checks_image" >> "$out/checks.log" 2>&1; then
    job_exit=0
  else
    job_exit=$?
  fi
  echo "::: job $job" >> "$out/checks-proxy.log"
  docker logs "$net-proxy" >> "$out/checks-proxy.log" 2>&1 || true
  docker ps -aq --filter "label=local-ci.run=$ns" --filter "label=local-ci.job=$job" \
    | xargs docker rm -f >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work/checks-$job"
}

# --- checks -----------------------------------------------------------------------------------
# One job at a time, in ci.yml's order, stopping at the first that fails.
: > "$out/checks.log"
: > "$out/checks-proxy.log"
: > "$out/modules.log"
if [ "$skipped" != "{}" ]; then
  echo "local-ci: CI-only, not run here: $(jq -r 'to_entries | map("\(.key) (\(.value))") | join(", ")' <<<"$skipped")" >&2
fi
t_checks=$SECONDS
checks_exit=0
# By index, not `while read`: anything in a job that read stdin would eat the remaining entries.
for i in $(seq 0 $(($(jq length <<<"$plan") - 1))); do
  entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$plan")"
  job="$(jq -r .name <<<"$entry")"
  jcfg="$(jq -c .cfg <<<"$entry")"
  inputs="$(jq -c .inputs <<<"$entry")"
  wd="$(jq -r .wd <<<"$entry")"
  go_version="$(jq -r .go_version <<<"$entry")"
  t0=$SECONDS
  run_go_job
  checks_jobs="$(jq -c --arg n "$job" --argjson e "$job_exit" --argjson s "$((SECONDS - t0))" \
    '. + {($n): {exit: $e, seconds: $s}}' <<<"$checks_jobs")"
  if [ "$job_exit" -ne 0 ]; then
    checks_exit=$job_exit
    break
  fi
done
checks_s=$((SECONDS - t_checks))

if [ "$checks_exit" -ne 0 ]; then
  write_result fail-checks "$checks_exit" null null
  tail -40 "$out/checks.log" >&2
  echo "local-ci: checks FAILED in job '$job' (exit $checks_exit, ${checks_s}s); no review of code that fails CI" >&2
  exit 1
fi
job=""
echo "local-ci: checks passed (${checks_s}s)" >&2

# --- review -----------------------------------------------------------------------------------
state review
echo "local-ci: review of ${base:0:12}...${sha:0:12} with $MODEL ($EFFORT) (log: $out/review.log)" >&2
t0=$SECONDS
docker network create --internal --label "local-ci.run=$ns" "$ns-review" >/dev/null
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
