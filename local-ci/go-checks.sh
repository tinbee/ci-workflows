#!/usr/bin/env bash
# Runs inside the local-ci checks container (checks.Dockerfile): go-ci.yml's steps, in
# go-ci.yml's order, with the inputs the commit's own ci.yml passes it (defaults filled in by
# run.sh), then the repo's `after` script for what its ci.yml runs outside go-ci. Stops at
# the first failure.
#
# Not run here, on purpose:
#   pre_command      CI's machine setup (woahbar starts Postgres with it); .local-ci.yml
#                    `services` replace it.
#   private modules  run.sh pre-fetches them on the host; this container reads them from a
#                    read-only file proxy, checked against go.sum, and holds no credential.
#                    The tools ci.yml `go run`s at a version come from the same proxy.
#
# stdin: a tar of tree/ (the files of $SHA) and inputs.json (go-ci's inputs, plus `after`).
set -euo pipefail

in=/tmp/in
mkdir -p "$in"
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C "$in"

mkdir -p ~/work
mv "$in/tree" ~/work/repo
cd ~/work/repo
# A one-commit repository of exactly those files, so `git diff` (the generated-code check) and
# `git ls-files` behave as on a checkout. -f: a tracked file that also matches .gitignore is
# still part of the commit.
git init -q
git add -A -f
git -c user.name=local-ci -c user.email=local-ci@localhost commit -q --no-verify -m "$SHA"
root="$PWD"

# Not `.[$k] // ""`: jq's `//` treats false as missing.
input() { jq -r --arg k "$1" '.[$k] | if . == null then "" else tostring end' "$in/inputs.json"; }

# go-ci sets env_json before anything else. Variables run.sh already set (from
# .local-ci.yml `env`) win: env_json carries CI's hostnames, such as a Postgres on 127.0.0.1.
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] || continue
  if [ -z "${!key+x}" ]; then export "$key=$value"; fi
done < <(jq -r '(.env_json // "{}") | fromjson | to_entries[] | "\(.key)\t\(.value)"' "$in/inputs.json")

cd "$(input working_directory)"

# Each command runs as its own bash script, under `-e -o pipefail`, as a GitHub `run:` does.
step() { # <name> <command>
  echo "::: $1"
  local t0=$SECONDS f
  f="$(mktemp)"
  printf '%s\n' "$2" > "$f"
  bash -eo pipefail "$f"
  echo "::: $1 ok ($((SECONDS - t0))s)"
}

if [ -n "$(input generate_command)" ]; then
  step "Generated code is current" "$(input generate_command)
if ! git diff --exit-code -- $(input generated_paths); then
  echo 'generated code is stale -- regenerate and commit'
  exit 1
fi"
fi

[ -z "$(input lint_command)" ] || step "Lint" "$(input lint_command)"

# golangci-lint-action with no args runs `golangci-lint run` in the working directory.
[ -z "$(input golangci_version)" ] || step "golangci-lint $(input golangci_version)" "golangci-lint run"

if [ "$(input gofmt_check)" = true ]; then
  # shellcheck disable=SC2016 # expanded by the step's own bash, not here
  step "gofmt" 'unformatted=$(find . -path ./vendor -prune -o -name "*.go" -type f -print0 | xargs -0 -r gofmt -l)
if [ -n "$unformatted" ]; then
  echo "gofmt would change these files:"
  printf "%s\n" "$unformatted"
  exit 1
fi'
fi

# Its modules, tests of dependencies included, were fetched on the host (run.sh).
[ "$(input tidy_check)" != true ] || step "go.mod and go.sum are tidy" "go mod tidy -diff"

[ -z "$(input build_command)" ] || step "Build" "$(input build_command)"

[ -z "$(input test_command)" ] || step "Test" "export GOFLAGS=\"\${GOFLAGS:+\$GOFLAGS }-count=1\"
$(input test_command)"

# Through the proxy to vuln.go.dev: the one check that needs the network, and the one that
# caught GO-2026-6859 only in CI before this ran locally.
[ "$(input govulncheck)" != true ] || step "govulncheck" "govulncheck ./..."

[ -z "$(input post_command)" ] || step "Post-command" "$(input post_command)"

after="$(input after)"
if [ -n "$after" ]; then
  cd "$root"
  [ -f "$after" ] || { echo "local-ci: .local-ci.yml names after: $after, which this commit does not have"; exit 1; }
  step "after: $after" "bash $(printf '%q' "$after")"
fi
