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
    # -e, not -d: in a worktree or a --separate-git-dir checkout, .git is a file.
    if [ -e "$c/.git" ]; then ciw="$c"; break; fi
  done
fi
if [ -z "$ciw" ] || [ ! -e "$ciw/.git" ]; then
  echo "local-ci: no tinbee/ci-workflows checkout found; clone it or set LOCAL_CI_RULES_REPO" >&2
  exit 3
fi

# v1 floats: refresh it, so this runs what the label review runs today. This also runs in the
# pre-push hook, so it must not hang a push: no prompts, and a bounded stall over HTTPS
# (lowSpeedLimit/Time) and SSH (connect and keepalive timeouts). On failure, the local copy.
# The timeouts are added to the ssh command git would use anyway (GIT_SSH_COMMAND, else
# core.sshCommand), since GIT_SSH_COMMAND would otherwise replace a configured one.
ssh_cmd="${GIT_SSH_COMMAND:-$(git -C "$ciw" config core.sshCommand 2>/dev/null || echo ssh)}"
if ! GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2" \
  git -C "$ciw" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
  fetch -q --force origin "refs/tags/$ref:refs/tags/$ref" 2>/dev/null; then
  echo "local-ci: could not refresh $ref of $ciw; using the local copy" >&2
fi

shared="$(mktemp -d)"
trap 'rm -rf "$shared"' EXIT
if ! git -C "$ciw" archive "$ref" local-ci review review-rules .github/workflows/go-ci.yml \
  | tar -x -C "$shared"; then
  echo "local-ci: $ref of $ciw has no local-ci/ (it is v1.23.0+)" >&2
  exit 3
fi
LOCAL_CI_SHARED="$shared" bash "$shared/local-ci/run.sh" "$@"
