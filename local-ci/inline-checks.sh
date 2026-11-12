#!/usr/bin/env bash
# Runs inside the local-ci checks container for a ci.yml job written inline (node.Dockerfile):
# the job's own `run:` steps, in ci.yml's order, each in its working-directory with its env (the
# job's, then the step's, then .local-ci.yml `env` over both; run.sh merged them) and its shell,
# as a GitHub runner runs them. The setup actions the job used chose this image's Node, pnpm and
# Go; installs are offline, from the caches node-fetch.sh filled. Stops at the first failure.
#
# stdin: a tar of tree/ (the files of $SHA) and inputs.json ({steps: [{run, env, wd, shell}]}).
set -euo pipefail

in=/tmp/in
mkdir -p "$in"
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C "$in"

mkdir -p ~/work
mv "$in/tree" ~/work/repo
cd ~/work/repo
# A one-commit repository of exactly those files, so `git status --porcelain` and `git ls-files`
# behave as on a checkout. -f: a tracked file that also matches .gitignore is still part of it.
git init -q
git add -A -f
git -c user.name=local-ci -c user.email=local-ci@localhost commit -q --no-verify -m "$SHA"
root="$PWD"

steps="$(jq '.steps | length' "$in/inputs.json")"
for i in $(seq 0 $((steps - 1))); do
  step() { jq -r --argjson i "$i" ".steps[\$i].$1" "$in/inputs.json"; }
  f="$(mktemp)"
  step run > "$f"
  # GitHub's own command lines: unnamed is `bash -e`, `bash` adds pipefail and no rc files.
  case "$(step shell)" in
    default) cmd=(bash -e "$f") ;;
    bash) cmd=(bash --noprofile --norc -eo pipefail "$f") ;;
    sh) cmd=(sh -e "$f") ;;
  esac
  echo "::: step $((i + 1)): $(head -1 "$f")"
  t0=$SECONDS
  (
    cd "$root/$(step wd)"
    # NUL-separated, so a value cannot become a second variable.
    while IFS= read -r -d '' kv; do export "${kv?}"; done < <(jq -j --argjson i "$i" \
      '.steps[$i].env | to_entries[] | "\(.key)=\(.value | tostring)\u0000"' "$in/inputs.json")
    "${cmd[@]}"
  )
  echo "::: step $((i + 1)) ok ($((SECONDS - t0))s)"
done
