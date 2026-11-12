#!/usr/bin/env bash
# Runs inside the local-ci checks container for a node-pnpm-ci.yml job (node.Dockerfile):
# node-pnpm-ci.yml's steps, in its order, with the inputs the commit's own ci.yml passes it
# (defaults filled in by run.sh), then the job's `after` script. Stops at the first failure.
#
# The install is offline, from a copy of the store node-fetch.sh filled (pnpm_config_* in the
# environment, set by run.sh), so the commit's own install_command runs as it is written.
#
# Not run here, on purpose:
#   coverage_command  CI runs it instead of test_command only on a push to the default
#                     branch; a commit checked before its push is the PR case, test_command.
#   turbo_*           the remote cache needs a token; turbo runs without it.
#
# stdin: a tar of tree/ (the files of $SHA) and inputs.json (the job's inputs, plus `after`).
set -euo pipefail

in=/tmp/in
mkdir -p "$in"
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C "$in"

mkdir -p ~/work
mv "$in/tree" ~/work/repo
cd ~/work/repo
# A one-commit repository of exactly those files, so `git status --porcelain` (a generated-file
# check) and `git ls-files` behave as on a checkout. -f: a tracked file that also matches
# .gitignore is still part of the commit.
git init -q
git add -A -f
git -c user.name=local-ci -c user.email=local-ci@localhost commit -q --no-verify -m "$SHA"

# Not `.[$k] // ""`: jq's `//` treats false as missing.
input() { jq -r --arg k "$1" '.[$k] | if . == null then "" else tostring end' "$in/inputs.json"; }

# node-pnpm-ci sets env_json before anything else. Variables run.sh already set (from
# .local-ci.yml `env`) win: env_json carries CI's hostnames.
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] || continue
  if [ -z "${!key+x}" ]; then export "$key=$value"; fi
done < <(jq -r '(.env_json // "{}") | fromjson | to_entries[] | "\(.key)\t\(.value)"' "$in/inputs.json")

# Each command runs as its own bash script, under `-e -o pipefail`, as a GitHub `run:` does.
step() { # <name> <command>
  echo "::: $1"
  local t0=$SECONDS f
  f="$(mktemp)"
  printf '%s\n' "$2" > "$f"
  bash -eo pipefail "$f"
  echo "::: $1 ok ($((SECONDS - t0))s)"
}

run_input() { # <step name> <input>
  local cmd
  cmd="$(input "$2")"
  [ -z "$cmd" ] || step "$1" "$cmd"
}
run_input "Install dependencies" install_command
run_input "Pre-check" pre_check_command
run_input "Format check" format_check_command
run_input "Lint" lint_command
run_input "Typecheck" typecheck_command
run_input "Build" build_command
run_input "Test" test_command

after="$(input after)"
if [ -n "$after" ]; then
  [ -f "$after" ] || { echo "local-ci: .local-ci.yml names after: $after, which this commit does not have"; exit 1; }
  step "after: $after" "bash $(printf '%q' "$after")"
fi
