#!/usr/bin/env bash
# local-ci: this repo's CI checks, then a cold-context Claude review, on a commit, before it is
# pushed. The runner lives in tinbee/ci-workflows (local-ci/), at LOCAL_CI_RULES_REF (v1),
# read from a local checkout of it; this file only fetches it. This repo's own part is
# .local-ci.yml. Copied from tinbee/ci-workflows local-ci/consumer-local-ci.sh.
#
#   scripts/local-ci.sh [--base <ref>] [<commit>]   checks + review (make local-ci)
#   scripts/local-ci.sh accept <commit> <reason>    override a fail-review you judged wrong
#   scripts/local-ci.sh install-hook                gate pushes on a passing result
set -euo pipefail

top="$(git rev-parse --show-toplevel)"
ref="${LOCAL_CI_RULES_REF:-v1}"
ciw="${LOCAL_CI_RULES_REPO:-}"
if [ -z "$ciw" ]; then
  for c in "$top/../ci-workflows" "$top/../../tinbee/ci-workflows" "$HOME/workspace/tinbee/ci-workflows"; do
    if [ -d "$c/.git" ]; then ciw="$c"; break; fi
  done
fi
if [ -z "$ciw" ] || [ ! -d "$ciw/.git" ]; then
  echo "local-ci: no tinbee/ci-workflows checkout found; clone it or set LOCAL_CI_RULES_REPO" >&2
  exit 3
fi

# v1 floats: refresh it, so this runs what the label review runs today.
git -C "$ciw" fetch -q --force origin "refs/tags/$ref:refs/tags/$ref" 2>/dev/null \
  || echo "local-ci: could not refresh $ref of $ciw; using the local copy" >&2

shared="$(mktemp -d)"
trap 'rm -rf "$shared"' EXIT
if ! git -C "$ciw" archive "$ref" local-ci review review-rules .github/workflows/go-ci.yml \
  | tar -x -C "$shared"; then
  echo "local-ci: $ref of $ciw has no local-ci/ (it is v1.23.0+)" >&2
  exit 3
fi
LOCAL_CI_SHARED="$shared" "$shared/local-ci/run.sh" "$@"
