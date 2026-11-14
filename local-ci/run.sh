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
# Result: <git common dir>/local-ci/<sha>/result.json; each review's cost, also in
# <git common dir>/local-ci/costs.jsonl.
#
# What each container can reach:
#   checks  the commit; go-ci's or node-pnpm-ci's steps as the commit's own ci.yml configures
#           them, one container per ci.yml job; that job's .local-ci.yml services, on its own
#           --internal network; the Go modules (every module in the commit, and each
#           `go run tool@version` in ci.yml), pre-fetched on the host into a read-only file
#           proxy; and, through a proxy, only the hosts in checks-allow.txt (read-only
#           hosts: vuln.go.dev and the like). For a node-pnpm-ci job, a copy of the repository's pnpm store, which
#           a fetch container filled from the lockfile alone (it alone reaches the npm
#           registry, and runs nothing of the commit's). No credential.
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
if [ ! -f "$h" ]; then
  echo "local-ci: this branch has no scripts/local-ci.sh, so the push is not checked" >&2
  exit 0
fi
# By bash, not by the file's mode: a copy that lost its executable bit must not switch the
# check off.
exec bash "$h" pre-push "$@"
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

# The branch the commit is on, recorded in state.json while it can still be named: once its PR
# is squash-merged and the branch deleted, no ref contains the commit. The ref given, when it
# is a local branch; else the checked-out branch, when HEAD is this commit; else the nearest
# local branch (`name-rev`, so a commit behind the tip reads `<branch>~<n>`). Empty if none.
branch=""
if [ -n "${1:-}" ] && git show-ref --verify -q "refs/heads/$1"; then
  branch="$1"
elif [ "$sha" = "$(git rev-parse HEAD)" ]; then
  branch="$(git branch --show-current)"
fi
if [ -z "$branch" ]; then
  branch="$(git name-rev --name-only --no-undefined --refs='refs/heads/*' "$sha" 2>/dev/null)" || branch=""
fi

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
in_dir() { # <dir> <path>: <path> inside <dir>, without a leading ./ (which git reads as cwd)
  if [ "$1" = . ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

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

# A `${{ }}` in what ci.yml passes the workflow is GitHub's to evaluate, not this script's: it
# stops the run, naming the input. Except in env_json, where .local-ci.yml `env` (which wins
# over env_json in any case) can give the variable a value: an expression there stops the run
# only when it has none, as `vars.VITE_API_URL` would otherwise reach a build as that literal.
refuse_expressions() { # <ci.yml job> <its with, as JSON> <its .local-ci.yml settings, as JSON>
  local job="$1" with="$2" jcfg="$3" bad env_json unset
  bad="$(jq -c 'del(.env_json) | to_entries | map(select(.value | tostring | contains("${{"))) | from_entries' <<<"$with")"
  [ "$bad" = "{}" ] || die "ci.yml job '$job' passes a \${{ }} expression, which this cannot evaluate: $bad"
  env_json="$(jq -r '.env_json // "{}" | tostring' <<<"$with")"
  # shellcheck disable=SC2016 # the literal text ${{, not an expansion
  [[ "$env_json" == *'${{'* ]] || return 0
  unset="$(jq -r --argjson set "$(jq -c '.env // {}' <<<"$jcfg")" \
    'to_entries | map(select(. as $e | ($e.value | tostring | contains("${{")) and ($set | has($e.key) | not)) | .key) | join(", ")' \
    <<<"$env_json" 2>/dev/null)" || die "ci.yml job '$job' passes env_json that is not JSON once its \${{ }} expressions are text"
  [ -z "$unset" ] || die "ci.yml job '$job' sets $unset in env_json from a \${{ }} expression, which this cannot evaluate; give each a value under jobs.$job.env in .local-ci.yml"
}

# The toolchain versions the setup actions would install, read from the commit. Each reaches a
# Dockerfile's FROM or RUN lines and an image tag, so each must match a pattern first.
go_version_of() { # <go.mod path>: its toolchain line if it has one, else its go line, as setup-go reads it
  local v
  must_be_relative_path "go version file" "$1"
  v="$(git show "$sha:$1" 2>/dev/null | awk '
    $1 == "go" && go == "" { go = $2 }
    $1 == "toolchain" && $2 ~ /^go[0-9]/ { tc = substr($2, 3) }
    END { print (tc != "" ? tc : go) }')" || v=""
  [ -n "$v" ] || die "no go or toolchain line in $1 at ${sha:0:12}"
  must_match "go version" "$v" '^[0-9]+\.[0-9]+(\.[0-9]+)?((rc|beta)[0-9]+)?$'
  printf '%s' "$v"
}
node_version_of() { # <node version file, or ""> <literal version>: as setup-node chooses between them
  local v="$2"
  if [ -n "$1" ]; then
    must_be_relative_path "node version file" "$1"
    v="$(git show "$sha:$1" 2>/dev/null | head -1 | tr -d '[:space:]')" || v=""
    [ -n "$v" ] || die "no node version in $1 at ${sha:0:12}"
  fi
  v="${v#v}"
  must_match "node version" "$v" '^[0-9]+(\.[0-9]+){0,2}$'
  printf '%s' "$v"
}
pnpm_version_of() { # package.json's packageManager, which pnpm/action-setup reads when given no version
  local pm
  pm="$(git show "$sha:package.json" 2>/dev/null | jq -r '.packageManager // ""')" || pm=""
  [[ "$pm" =~ ^pnpm@([0-9]+\.[0-9]+\.[0-9]+)(\+.*)?$ ]] \
    || die "package.json at ${sha:0:12} has no packageManager pnpm@<x.y.z> (it has '$pm'), which pnpm/action-setup needs as well"
  printf '%s' "${BASH_REMATCH[1]}"
}

plan_go_job() { # <ci.yml job> <its .local-ci.yml settings, as JSON>
  local job="$1" jcfg="$2" with after wd go_version
  with="$(jq -c --arg j "$job" '.jobs[$j].with // {}' <<<"$ci")"
  refuse_expressions "$job" "$with" "$jcfg"
  after="$(jq -r '.after // ""' <<<"$jcfg")"
  [ -z "$after" ] || must_be_relative_path "after" "$after"
  inputs="$(jq -c -n --argjson d "$defaults" --argjson w "$with" --arg after "$after" '$d + $w + {after: $after}')"

  # These reach a Dockerfile's RUN lines (as build args), an image tag and git paths.
  must_match "buf" "$(input buf)" '^(true|false)$'
  must_match "govulncheck" "$(input govulncheck)" '^(true|false)$'
  must_match "tidy_check" "$(input tidy_check)" '^(true|false)?$'
  must_match "sqlc_version" "$(input sqlc_version)" '^([0-9]+\.[0-9]+\.[0-9]+)?$'
  must_match "golangci_version" "$(input golangci_version)" '^(v[0-9]+(\.[0-9]+){0,2})?$'
  wd="$(input working_directory)"
  wd="${wd:-.}"
  must_be_relative_path "working_directory" "$wd"
  must_be_relative_path "go_version_file" "$(input go_version_file)"
  go_version="$(go_version_of "$(in_dir "$wd" "$(input go_version_file)")")"

  plan="$(jq -c --arg n "$job" --argjson c "$jcfg" --argjson i "$inputs" --arg wd "$wd" --arg g "$go_version" \
    '. + [{name: $n, kind: "go", cfg: $c, inputs: $i, wd: $wd, go_version: $g}]' <<<"$plan")"
}

plan_node_job() { # <ci.yml job> <its .local-ci.yml settings, as JSON>
  local job="$1" jcfg="$2" with after node_defaults node_version pnpm_version
  local wf="$shared/.github/workflows/node-pnpm-ci.yml"
  [ -f "$wf" ] || die "ci.yml job '$job' calls node-pnpm-ci.yml, which this scripts/local-ci.sh does not extract; copy the current consumer-local-ci.sh from tinbee/ci-workflows local-ci/"
  node_defaults="$(yq -o json '.on.workflow_call.inputs | map_values(.default)' "$wf")"
  # Not the turbo remote cache's inputs: local-ci runs turbo without it, so whatever expression
  # ci.yml passes for them (`vars.TURBO_API`) has nothing here to stop.
  with="$(jq -c --arg j "$job" '.jobs[$j].with // {} | del(.turbo_api, .turbo_team)' <<<"$ci")"
  refuse_expressions "$job" "$with" "$jcfg"
  after="$(jq -r '.after // ""' <<<"$jcfg")"
  [ -z "$after" ] || must_be_relative_path "after" "$after"
  inputs="$(jq -c -n --argjson d "$node_defaults" --argjson w "$with" --arg after "$after" '$d + $w + {after: $after}')"

  node_version="$(node_version_of "$(input node_version_file)" "$(input node_version)")"
  pnpm_version="$(pnpm_version_of)"

  plan="$(jq -c --arg n "$job" --argjson c "$jcfg" --argjson i "$inputs" --arg nv "$node_version" --arg pv "$pnpm_version" \
    '. + [{name: $n, kind: "node", cfg: $c, inputs: $i, node_version: $nv, pnpm_version: $pv}]' <<<"$plan")"
}

# A job ci.yml writes inline: its own `run:` steps, in order, with its env. Its setup actions
# say what the image needs (checkout; pnpm/action-setup, setup-node, setup-go and their
# versions). Any other action, an `if:`, a `container:` or a matrix is GitHub's to run, and stops
# the run naming it: its effect cannot be known here. So do services ci.yml gives the job that
# .local-ci.yml does not, since local-ci starts its own (on 127.0.0.1, as CI's are).
plan_inline_job() { # <ci.yml job> <its .local-ci.yml settings, as JSON>
  local job="$1" jcfg="$2" jobj step uses action with file shell wd run stepenv unset k i n
  local node_version="" pnpm_version="" go_version="" steps="[]" local_env
  jobj="$(jq -c --arg j "$job" '.jobs[$j]' <<<"$ci")"
  [ -z "$(jq -r '.after // ""' <<<"$jcfg")" ] || die "jobs.$job: after is for a reusable-workflow job; an inline job runs its own steps"
  for k in container strategy; do
    if jq -e --arg k "$k" 'has($k)' <<<"$jobj" >/dev/null; then die "ci.yml job '$job' sets $k:, which local-ci cannot run (skip: <reason>)"; fi
  done
  if jq -e '(.services // {}) | length > 0' <<<"$jobj" >/dev/null && ! jq -e '(.services // {}) | length > 0' <<<"$jcfg" >/dev/null; then
    die "ci.yml job '$job' has services: give them under jobs.$job.services in .local-ci.yml (local-ci starts them on 127.0.0.1, as CI does)"
  fi
  local_env="$(jq -c '.env // {}' <<<"$jcfg")"
  n="$(jq '(.steps // []) | length' <<<"$jobj")"
  for i in $(seq 0 $((n - 1))); do
    step="$(jq -c --argjson i "$i" '.steps[$i]' <<<"$jobj")"
    if jq -e 'has("if")' <<<"$step" >/dev/null; then die "ci.yml job '$job' step $((i + 1)) has an if:, which only GitHub can evaluate (skip: <reason>)"; fi
    uses="$(jq -r '.uses // ""' <<<"$step")"
    if [ -n "$uses" ]; then
      action="${uses%%@*}"
      with="$(jq -c '.with // {}' <<<"$step")"
      # shellcheck disable=SC2016 # the literal text ${{, not an expansion
      if [[ "$with" == *'${{'* ]]; then die "ci.yml job '$job' passes a \${{ }} expression to $action, which this cannot evaluate"; fi
      case "$action" in
        actions/checkout) ;;
        pnpm/action-setup)
          [ "$(jq -r '.version // ""' <<<"$with")" = "" ] || die "ci.yml job '$job' gives pnpm/action-setup a version; local-ci reads it from package.json's packageManager only"
          pnpm_version="$(pnpm_version_of)" ;;
        actions/setup-node)
          node_version="$(node_version_of "$(jq -r '."node-version-file" // ""' <<<"$with")" "$(jq -r '."node-version" // ""' <<<"$with")")" ;;
        actions/setup-go)
          file="$(jq -r '."go-version-file" // ""' <<<"$with")"
          if [ -n "$file" ]; then
            go_version="$(go_version_of "$file")"
          else
            go_version="$(jq -r '."go-version" // ""' <<<"$with")"
            must_match "go version" "$go_version" '^[0-9]+\.[0-9]+\.[0-9]+$'
          fi ;;
        *) die "ci.yml job '$job' uses $action, which local-ci cannot run (skip: <reason>)" ;;
      esac
      continue
    fi
    run="$(jq -r '.run // ""' <<<"$step")"
    [ -n "$run" ] || die "ci.yml job '$job' step $((i + 1)) has neither run: nor uses:"
    # shellcheck disable=SC2016 # the literal text ${{, not an expansion
    if [[ "$run" == *'${{'* ]]; then die "ci.yml job '$job' step $((i + 1)) runs a \${{ }} expression, which this cannot evaluate"; fi
    shell="$(jq -r '.shell // "default"' <<<"$step")"
    case "$shell" in default | bash | sh) ;; *) die "ci.yml job '$job' step $((i + 1)) runs under $shell; local-ci runs bash and sh" ;; esac
    wd="$(jq -r '."working-directory" // "."' <<<"$step")"
    must_be_relative_path "working-directory" "$wd"
    # The job's env, then the step's, then .local-ci.yml's, which wins: it sets what an
    # expression would have, and what CI's published ports would make different here.
    stepenv="$(jq -c --argjson job "$(jq -c '.env // {}' <<<"$jobj")" '$job + (.env // {})' <<<"$step")"
    unset="$(jq -r --argjson set "$local_env" 'to_entries | map(select(. as $e | ($e.value | tostring | contains("${{")) and ($set | has($e.key) | not)) | .key) | join(", ")' <<<"$stepenv")"
    [ -z "$unset" ] || die "ci.yml job '$job' sets $unset from a \${{ }} expression, which this cannot evaluate; give each a value under jobs.$job.env in .local-ci.yml"
    stepenv="$(jq -c --argjson set "$local_env" '. + $set' <<<"$stepenv")"
    jq -e 'to_entries | all((.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and ((.value | tostring) | test("[\n\r\u0000]") | not))' <<<"$stepenv" >/dev/null \
      || die "ci.yml job '$job' step $((i + 1)): an env entry is not NAME: one-line value"
    steps="$(jq -c --arg run "$run" --argjson env "$stepenv" --arg wd "$wd" --arg shell "$shell" \
      '. + [{run: $run, env: $env, wd: $wd, shell: $shell}]' <<<"$steps")"
  done
  [ "$(jq length <<<"$steps")" -gt 0 ] || die "ci.yml job '$job' has no run: steps"
  # A runner has Node whether or not the job sets it up; so does this image, at the active LTS.
  node_version="${node_version:-22}"
  inputs="$(jq -c -n --argjson steps "$steps" '{steps: $steps, after: "", commands_text: ($steps | map(.run) | join("\n"))}')"
  plan="$(jq -c --arg n "$job" --argjson c "$jcfg" --argjson i "$inputs" --arg nv "$node_version" --arg pv "$pnpm_version" --arg g "$go_version" \
    '. + [{name: $n, kind: "inline", cfg: $c, inputs: $i, wd: ".", node_version: $nv, pnpm_version: $pv, go_version: $g}]' <<<"$plan")"
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
      */node-pnpm-ci.yml@*) plan_node_job "$job" "$jcfg" ;;
      "") plan_inline_job "$job" "$jcfg" ;;
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
    --arg branch "$branch" \
    '{sha: $sha, base: $base, pid: $pid, ns: $ns, phase: $phase, started: $started, updated: $at}
     + (if $branch == "" then {} else {branch: $branch} end)
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
  docker volume ls -q --filter "label=local-ci.run=$ns" | xargs docker volume rm >/dev/null 2>&1 || true
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
#
# A review the model answered also appends one line to <git common dir>/local-ci/costs.jsonl:
# its cost under the same `created`, kept when a re-run of the commit replaces result.json or
# Clean up deletes it, and written for an `error` too, whose result has no review to carry it.
write_result() { # <status> <checks exit> <review json or null> <envelope json or null>
  local at
  at="$(date -u +%FT%TZ)"
  jq -n --arg sha "$sha" --arg base "$base" --arg status "$1" --argjson checks_exit "$2" \
    --argjson review "$3" --argjson envelope "$4" --arg model "$MODEL" --arg effort "$EFFORT" \
    --arg at "$at" --argjson checks_s "${checks_s:-0}" --argjson review_s "${review_s:-0}" \
    --argjson jobs "$checks_jobs" \
    '{sha: $sha, base: $base, status: $status, created: $at,
      seconds: {checks: $checks_s, review: $review_s},
      checks: {exit: $checks_exit, jobs: $jobs},
      review: (if $review == null then null else $review + {
        model: $model, effort: $effort,
        turns: $envelope.num_turns, cost_usd: $envelope.total_cost_usd} end)}' \
    > "$out/result.json"
  jq -nc --arg sha "$sha" --arg status "$1" --argjson envelope "$4" --arg model "$MODEL" \
    --arg effort "$EFFORT" --arg at "$at" --argjson review_s "${review_s:-0}" \
    'if ($envelope | type) == "object" and ($envelope.total_cost_usd | type) == "number" then
       {created: $at, sha: $sha, status: $status, model: $model, effort: $effort,
        seconds: $review_s, cost_usd: $envelope.total_cost_usd}
     else empty end' >> "$results/costs.jsonl"
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
  # A file of its own per call: jobs run side by side, and a shared one mixed their env.
  local kv file
  file="$(mktemp "$work/env.XXXXXX")"
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
host_go_env() { # <command...>: go on the host, fetching into the shared cache
  GOMODCACHE="$GOMODCACHE_HOST" GOWORK=off GOFLAGS=-mod=mod GOPRIVATE="$host_goprivate" \
    GONOPROXY='' GONOSUMDB='' GOINSECURE='' GOVCS='private:git,public:off' GOTOOLCHAIN=local "$@"
}
fetch_modules() { # for the job in $wd and $inputs; sets module_flags
  local host_goprivate mods=() tools=() m k tool dir tidy_dir
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
    for k in generate_command lint_command build_command test_command post_command commands_text; do input "$k"; done
    [ -z "$(input after)" ] || git show "$sha:$(input after)" 2>/dev/null || true
  } > "$work/commands.txt"
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    # An exact version, so the container can resolve it from the cache with no listing.
    must_match "go run/install target" "$tool" '^[A-Za-z0-9][A-Za-z0-9._~/-]*@v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.+-]*)?$'
    tools+=("$tool")
  done < <(grep -oE 'go +(run|install) +(-[^[:space:]]+ +)*["'"'"']?[^[:space:]"'"'"'-][^[:space:]"'"'"']*@[^[:space:]);&|"'"'"']+' \
    "$work/commands.txt" | awk '{ print $NF }' | tr -d "\"'" | sort -u || true)
  tidy_dir=""
  [ "$(input tidy_check)" != true ] || tidy_dir="$wd"
  [ ${#mods[@]} -gt 0 ] || [ ${#tools[@]} -gt 0 ] || [ -n "$tidy_dir" ] || return 0

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
  # tidy_check: `go mod tidy` also loads the tests of every dependency's packages, so it needs
  # modules `go mod download` leaves out (testify, for gokit's). Running it here fetches them.
  # -diff writes nothing and runs no module code, and the verdict is the container's to give,
  # so its exit is ignored: a module it could not fetch fails the container's run by name.
  if [ -n "$tidy_dir" ]; then
    echo "::: job $job: $tidy_dir (go mod tidy)" >> "$out/modules.log"
    (cd "$work/tree/$tidy_dir" && host_go_env go mod tidy -diff) >> "$out/modules.log" 2>&1 || true
  fi
  module_flags=(-v "$GOMODCACHE_HOST/cache/download:/goproxy:ro"
    -e GOPROXY=file:///goproxy -e GOSUMDB=off -e GOPRIVATE= -e GONOSUMDB=)
  # -mod=mod for an unvendored job only: in a vendored one it would bypass vendor/.
  if ! git cat-file -e "$sha:$(in_dir "$wd" vendor/modules.txt)" 2>/dev/null; then
    module_flags+=(-e GOFLAGS=-mod=mod)
  fi
}

# A go-ci job ($wd, $go_version): its modules and its image. Sets checks_image and job_flags.
prepare_go_job() {
  state modules
  fetch_modules
  job_flags=(${module_flags[@]+"${module_flags[@]}"})

  state images
  checks_image="local-ci-checks:go$go_version-buf$(input buf)-sqlc$(input sqlc_version)-golangci$(input golangci_version)-vuln$(input govulncheck)"
  echo "local-ci: building the checks image for '$job' (Go $go_version)" >&2
  docker build -q --build-arg GO_VERSION="$go_version" --build-arg BUF="$(input buf)" \
    --build-arg SQLC_VERSION="$(input sqlc_version)" --build-arg GOLANGCI_VERSION="$(input golangci_version)" \
    --build-arg GOVULNCHECK="$(input govulncheck)" -t "$checks_image" \
    -f "$shared/local-ci/checks.Dockerfile" "$shared/local-ci" >/dev/null \
    || die "could not build the checks image for Go $go_version"
}

# The image for a node-pnpm-ci or an inline job ($node_version, $pnpm_version and $go_version,
# either of the last two possibly empty). Sets checks_image.
build_node_image() {
  state images
  checks_image="local-ci-node:node$node_version-pnpm${pnpm_version:-none}-go${go_version:-none}"
  echo "local-ci: building the checks image for '$job' (Node $node_version${pnpm_version:+, pnpm $pnpm_version}${go_version:+, Go $go_version})" >&2
  docker build -q --build-arg NODE_VERSION="$node_version" --build-arg PNPM_VERSION="$pnpm_version" \
    --build-arg GO_VERSION="$go_version" -t "$checks_image" -f "$shared/local-ci/node.Dockerfile" "$shared/local-ci" >/dev/null \
    || die "could not build the checks image for Node $node_version${pnpm_version:+, pnpm $pnpm_version}${go_version:+, Go $go_version}"
}

# npm packages: a fetch container, given only the commit's manifests and lockfiles and running
# none of its code (node-fetch.sh), fills this repository's package caches, a Docker volume
# kept between runs, through a proxy that allows only the npm registry. The checks then get a
# COPY of that volume, made for this run and removed after it, and install offline. A copy
# because pnpm opens its store's index for writing, so a read-only mount does not install, and
# a shared writable one would let one commit's code change the packages a later run installs.
fetch_packages() { # <pnpm: 0|1> <npm: 0|1>; adds to job_flags
  local store="local-ci-pnpm-$repo_name" copy="$ns-pnpm-$job" fnet="$ns-fetch-$job" manifests
  state modules
  echo "local-ci: fetching the npm packages of '$job' into the volume $store" >&2
  echo "::: job $job: npm packages" >> "$out/modules.log"
  must_match "repository name" "$repo_name" '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
  docker volume create --label "local-ci.pnpm=$repo_name" "$store" >/dev/null
  docker run --rm --label "local-ci.run=$ns" --user 0 -v "$store:/pnpm" --entrypoint chown "$checks_image" node:node /pnpm
  manifests="$work/manifests-$job"
  # One path a line, unquoted: tar -T reads lines, and quotePath would escape non-ASCII names.
  git -c core.quotePath=false ls-tree -r --name-only "$sha" \
    | grep -E '(^|/)package\.json$|(^|/)package-lock\.json$|^pnpm-lock\.yaml$|^pnpm-workspace\.yaml$' \
    | grep -Ev '(^|/)node_modules/' > "$manifests" || true
  [ "$1" = 0 ] || grep -qx 'pnpm-lock.yaml' "$manifests" || die "${sha:0:12} has no pnpm-lock.yaml, which a frozen install needs"
  docker network create --internal --label "local-ci.run=$ns" "$fnet" >/dev/null
  start_proxy "$fnet" "$fnet-proxy" "$shared/local-ci/npm-allow.txt" "$job"
  if ! tar -C "$work/tree" -T "$manifests" -cf - | docker run --rm -i --label "local-ci.run=$ns" \
    --label "local-ci.job=$job" --network "$fnet" -e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888 \
    -e FETCH_PNPM="$1" -e FETCH_NPM="$2" \
    -v "$store:/pnpm" --entrypoint /opt/local-ci/node-fetch.sh "$checks_image" >> "$out/modules.log" 2>&1; then
    docker logs "$fnet-proxy" >> "$out/modules.log" 2>&1 || true
    tail -20 "$out/modules.log" >&2
    die "could not fetch ${sha:0:12}'s npm packages (log: $out/modules.log)"
  fi
  docker rm -f "$fnet-proxy" >/dev/null 2>&1 || true
  docker network rm "$fnet" >/dev/null 2>&1 || true

  docker volume create --label "local-ci.run=$ns" "$copy" >/dev/null
  docker run --rm --label "local-ci.run=$ns" --user 0 -v "$store:/s:ro" -v "$copy:/r" --entrypoint sh "$checks_image" \
    -c 'cp -a /s/. /r/ && chown node:node /r' || die "could not copy the package caches for this run"
  # ipv4first: with no IPv6 interface, as on these networks, getaddrinfo leaves ::1 out of
  # `localhost`, while Node would still listen on ::1 for it, so a test that serves on
  # localhost and fetches from it is refused (Foliot's packages/ui). GitHub's runners have
  # IPv6, where both agree. Not IPv6 on the network instead: whether --internal holds for IPv6
  # depends on the daemon's ip6tables setting. .local-ci.yml `env` can still set its own.
  job_flags+=(-v "$copy:/pnpm" -e pnpm_config_store_dir=/pnpm/store -e pnpm_config_cache_dir=/pnpm/cache
    -e pnpm_config_offline=true -e npm_config_cache=/pnpm/npm -e npm_config_offline=true
    -e npm_config_update_notifier=false -e CI=true -e NODE_OPTIONS=--dns-result-order=ipv4first)
  # pnpm 11 reads pnpm_config_*; pnpm 9 and 10 read only npm_config_* (`pnpm store path` with
  # each prefix: 9.15 and 10.12 follow npm_config_, 11.0 follows pnpm_config_). Without these
  # an older pnpm looks for its store in ~/.local/share/pnpm, finds nothing and, offline,
  # fails. Not for pnpm 11, where npm, run by an inline job, would warn about the unknown keys.
  if [ -n "$pnpm_version" ] && [ "${pnpm_version%%.*}" -lt 11 ]; then
    job_flags+=(-e npm_config_store_dir=/pnpm/store -e npm_config_cache_dir=/pnpm/cache)
  fi
}

# A node-pnpm-ci job ($node_version, $pnpm_version): its image, then its packages.
prepare_node_job() {
  build_node_image
  fetch_packages 1 0
}

# An inline job: its image (the toolchains its setup actions name), its Go modules when it sets
# Go up, then its npm packages, pnpm's and npm's both, since its own steps may run either.
prepare_inline_job() {
  build_node_image
  if [ -n "$go_version" ]; then
    state modules
    fetch_modules
    job_flags+=(${module_flags[@]+"${module_flags[@]}"})
  fi
  if [ -n "$pnpm_version" ]; then fetch_packages 1 1; else fetch_packages 0 1; fi
  job_flags+=(--entrypoint /opt/local-ci/inline-checks.sh)
}

# A job's image, modules and packages, from its plan entry ($job, $kind and the kind's fields),
# saved for execute_job: the image's name and the flags its container runs with. One job at a
# time: the jobs of one repository share its package store, which the fetch writes.
prepare_job() {
  local checks_image job_flags=()
  case "$kind" in
    go) prepare_go_job ;;
    node) prepare_node_job ;;
    inline) prepare_inline_job ;;
  esac
  printf '%s' "$checks_image" > "$work/image-$job"
  : > "$work/flags-$job"
  [ ${#job_flags[@]} -eq 0 ] || printf '%s\0' "${job_flags[@]}" > "$work/flags-$job"
}

# A prepared job's services, on a network of its own, then its checks; its output goes to
# $work/<job>.checks.log and .proxy.log, and its checks' exit to $work/exit-<job>, written only
# when they ran: a job with no exit file is one that could not run. In a subshell of its own,
# so jobs run side by side; a `die` here ends this job, not the run.
execute_job() {
  local net="$ns-job-$job" name image ready ok after checks_image no_proxy=localhost,127.0.0.1
  local names=() images=() aliases=() job_flags=() i f job_exit
  local log="$work/$job.checks.log" proxy_log="$work/$job.proxy.log"
  after="$(input after)"
  checks_image="$(cat "$work/image-$job")"
  while IFS= read -r -d '' f; do job_flags+=("$f"); done < "$work/flags-$job"

  echo "local-ci: checks on ${sha:0:12}: ci.yml job '$job' ($kind), then ${after:-no after script} (log: $out/checks.log)" >&2
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
    names+=("$name")
    images+=("$image")
    aliases+=(--network-alias "$name")
    no_proxy="$no_proxy,$name"
  done < <(jq -r '.services // {} | to_entries[] | "\(.key)\t\(.value.image)"' <<<"$jcfg")

  # The services and the checks share one network namespace, as a GitHub job's steps reach its
  # services on localhost: a test that insists on a database on this machine (Foliot's devseed)
  # finds one at 127.0.0.1. A holder container owns the namespace and carries each service's
  # name as an alias, so `postgres:5432` reaches it too. Two services cannot share a port.
  docker run -d --label "local-ci.run=$ns" --label "local-ci.job=$job" --name "$net--pod" \
    --network "$net" ${aliases[@]+"${aliases[@]}"} --entrypoint tail local-ci-proxy -f /dev/null >/dev/null
  for i in ${names[@]+"${!names[@]}"}; do
    name="${names[$i]}"
    env_flags_from "$(jq -c --arg n "$name" '.services[$n].env' <<<"$jcfg")"
    docker run -d --label "local-ci.run=$ns" --label "local-ci.job=$job" --name "$net-$name" \
      --network "container:$net--pod" ${env_flags[@]+"${env_flags[@]}"} "${images[$i]}" >/dev/null
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
  done

  env_flags_from "$(jq -c '.env' <<<"$jcfg")"

  # No build cache kept between runs: the commit's code can write to it, and Go trusts a cache
  # entry by its key, so one commit could plant a result a later commit's build would use.
  # In an `if`, so a failing check is a result here rather than an ERR.
  if tar -C "$work/checks-$job" -cf - . | docker run --rm -i --label "local-ci.run=$ns" \
    --label "local-ci.job=$job" --network "container:$net--pod" \
    -e SHA="$sha" -e HTTPS_PROXY=http://proxy:8888 -e HTTP_PROXY=http://proxy:8888 -e NO_PROXY="$no_proxy" \
    ${job_flags[@]+"${job_flags[@]}"} ${env_flags[@]+"${env_flags[@]}"} \
    "$checks_image" > "$log" 2>&1; then
    job_exit=0
  else
    job_exit=$?
  fi
  docker logs "$net-proxy" > "$proxy_log" 2>&1 || true
  docker ps -aq --filter "label=local-ci.run=$ns" --filter "label=local-ci.job=$job" \
    | xargs docker rm -f >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  # This job's own copy of the package caches only: another job may still be using its own.
  docker volume rm "$ns-pnpm-$job" >/dev/null 2>&1 || true
  rm -rf "$work/checks-$job"
  echo "$job_exit" > "$work/exit-$job"
}

# --- checks -----------------------------------------------------------------------------------
# Every job is prepared first, one at a time (image, modules, packages), then all of them run
# side by side, each on its own network with its own services, as CI's jobs do; the run waits
# for every one, as CI does, so a failure in one does not hide another's. A job's log goes into
# checks.log, under `::: job <name>`, when it finishes. LOCAL_CI_PARALLEL=0, or a bash older
# than 5.1 (no `wait -n -p`), runs them one at a time instead, through the same code.
: > "$out/checks.log"
: > "$out/checks-proxy.log"
: > "$out/modules.log"
if [ "$skipped" != "{}" ]; then
  echo "local-ci: CI-only, not run here: $(jq -r 'to_entries | map("\(.key) (\(.value))") | join(", ")' <<<"$skipped")" >&2
fi
parallel=1
if [ "${LOCAL_CI_PARALLEL:-1}" = 0 ] || ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1))); then
  parallel=0
fi
t_checks=$SECONDS
n_jobs="$(jq length <<<"$plan")"
load_entry() { # <index>: that plan entry's fields, as the job functions read them
  local entry
  entry="$(jq -c --argjson i "$1" '.[$i]' <<<"$plan")"
  job="$(jq -r .name <<<"$entry")"
  jcfg="$(jq -c .cfg <<<"$entry")"
  kind="$(jq -r .kind <<<"$entry")"
  inputs="$(jq -c .inputs <<<"$entry")"
  wd="$(jq -r '.wd // ""' <<<"$entry")"
  go_version="$(jq -r '.go_version // ""' <<<"$entry")"
  node_version="$(jq -r '.node_version // ""' <<<"$entry")"
  pnpm_version="$(jq -r '.pnpm_version // ""' <<<"$entry")"
}
# By index, not `while read`: anything in a job that read stdin would eat the remaining entries.
for i in $(seq 0 $((n_jobs - 1))); do
  load_entry "$i"
  prepare_job
done

job="$(jq -r 'map(.name) | join(",")' <<<"$plan")"
state checks
pids=()
names=()
job_t0=()
finish() { # <index>: that job's logs and exit, into the run's
  local j="${names[$1]}" e=""
  { echo "::: job $j"; cat "$work/$j.checks.log" 2>/dev/null || true; } >> "$out/checks.log"
  { echo "::: job $j"; cat "$work/$j.proxy.log" 2>/dev/null || true; } >> "$out/checks-proxy.log"
  [ ! -f "$work/exit-$j" ] || e="$(cat "$work/exit-$j")"
  checks_jobs="$(jq -c --arg n "$j" --arg e "$e" --argjson s "$((SECONDS - job_t0[$1]))" \
    '. + {($n): (if $e == "" then {error: "could not run", seconds: $s} else {exit: ($e | tonumber), seconds: $s} end)}' <<<"$checks_jobs")"
}
for i in $(seq 0 $((n_jobs - 1))); do
  load_entry "$i"
  job_t0+=("$SECONDS")
  names+=("$job")
  (execute_job) &
  pids+=("$!")
  if [ "$parallel" = 0 ]; then
    wait "$!" || true
    finish "$i"
  fi
done
if [ "$parallel" = 1 ]; then
  # Only the pids still running: `wait -n` given one that already finished returns it again at
  # once, every time, so a job that ended early would be counted for the others.
  running=("${pids[@]}")
  while [ "${#running[@]}" -gt 0 ]; do
    done_pid=""
    wait -n -p done_pid "${running[@]}" || true
    if [ -z "$done_pid" ]; then
      # Never seen, but no job may go unrecorded: a missing one would let the run pass. Wait
      # for each left, one by one, and record them all.
      for p in "${running[@]}"; do
        wait "$p" || true
        for i in "${!pids[@]}"; do
          if [ "${pids[$i]}" = "$p" ]; then finish "$i"; fi
        done
      done
      break
    fi
    for i in "${!pids[@]}"; do
      if [ "${pids[$i]}" = "$done_pid" ]; then finish "$i"; fi
    done
    left=()
    for p in "${running[@]}"; do [ "$p" = "$done_pid" ] || left+=("$p"); done
    running=(${left[@]+"${left[@]}"})
  done
fi
checks_s=$((SECONDS - t_checks))

failed="$(jq -r 'to_entries | map(select(.value.exit != null and .value.exit != 0) | .key) | join(", ")' <<<"$checks_jobs")"
broken="$(jq -r 'to_entries | map(select(.value.error != null) | .key) | join(", ")' <<<"$checks_jobs")"
if [ -n "$broken" ]; then
  tail -40 "$out/checks.log" >&2
  die "job(s) $broken could not run (${checks_s}s; log: $out/checks.log)"
fi
if [ -n "$failed" ]; then
  checks_exit="$(jq '[.[] | .exit // 0] | max' <<<"$checks_jobs")"
  write_result fail-checks "$checks_exit" null null
  tail -40 "$out/checks.log" >&2
  echo "local-ci: checks FAILED in $failed (${checks_s}s); no review of code that fails CI" >&2
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
