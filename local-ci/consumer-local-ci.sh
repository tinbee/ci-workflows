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

# git in the ci-workflows checkout. As the pre-push hook, this runs with GIT_DIR and friends
# exported for THIS repository, which githooks(5) says to clear before running git in
# another one: left set, `git -C "$ciw"` would read this repository instead.
ciw_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX git -C "$ciw" "$@"
}

# v1 floats: refresh it, so this runs what the label review runs today. This also runs in the
# pre-push hook, so it must not hang a push: no prompts, and a bounded stall over HTTPS
# (lowSpeedLimit/Time) and SSH (connect and keepalive timeouts). On failure, the local copy.
# The timeouts are added to the ssh command git would use anyway, in git's own order
# (GIT_SSH_COMMAND, core.sshCommand, GIT_SSH, ssh), since setting GIT_SSH_COMMAND here would
# otherwise replace whichever of those is configured.
ssh_cmd="${GIT_SSH_COMMAND:-}"
[ -n "$ssh_cmd" ] || ssh_cmd="$(ciw_git config core.sshCommand 2>/dev/null || true)"
[ -n "$ssh_cmd" ] || { [ -z "${GIT_SSH:-}" ] || ssh_cmd="$(printf '%q' "$GIT_SSH")"; }
ssh_cmd="${ssh_cmd:-ssh}"
if ! GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2" \
  ciw_git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
  fetch -q --force origin "refs/tags/$ref:refs/tags/$ref" 2>/dev/null; then
  echo "local-ci: could not refresh $ref of $ciw; using the local copy" >&2
fi

shared="$(mktemp -d)"
trap 'rm -rf "$shared"' EXIT
if ! ciw_git archive "$ref" local-ci review review-rules .github/workflows/go-ci.yml \
  | tar -x -C "$shared"; then
  echo "local-ci: $ref of $ciw has no local-ci/ (it is v1.23.0+)" >&2
  exit 3
fi
LOCAL_CI_SHARED="$shared" bash "$shared/local-ci/run.sh" "$@"
