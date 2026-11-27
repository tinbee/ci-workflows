#!/usr/bin/env bash
# Tests for run.sh's reuse of a job's pass (.local-ci.yml `inputs`). No Docker, no network, no
# token: `docker` is a fake that records which jobs' checks ran and decides their verdict from
# the files it is given, and the review is a fake that answers with no findings, or a blocking
# one when FAKE_REVIEW_BLOCKING=1. run.sh itself runs unchanged, against a throwaway consumer
# repository, with this checkout's local-ci/, review/ and workflows as its LOCAL_CI_SHARED.
#
#   ./local-ci/selftest.sh
#
# Every "reused" case is paired with a "runs" case that differs in one thing, so a reuse that
# is never taken, or always taken, fails one of the pair.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

for cmd in git jq yq; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd is required" >&2
    exit 2
  }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state"
export FAKE_STATE="$WORK/state"
: >"$FAKE_STATE/ran.log"
: >"$FAKE_STATE/reviewed.log"

# The user's git config (hooks, signing) has no business in the throwaway repository.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.invalid
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.invalid

# What consumer-local-ci.sh extracts, from this checkout instead of a tag.
SHARED="$WORK/shared"
mkdir -p "$SHARED/.github/workflows"
cp -R "$ROOT/local-ci" "$ROOT/review" "$ROOT/review-rules" "$SHARED/"
cp "$ROOT/.github/workflows/go-ci.yml" "$ROOT/.github/workflows/node-pnpm-ci.yml" "$SHARED/.github/workflows/"

# --- the fake ----------------------------------------------------------------------------------
# Every docker call run.sh makes succeeds and prints nothing, except:
#   image inspect   an id from the tag and FAKE_IMAGE_SALT, so a test can change the image
#   run -d          a container id
#   run, checks     (the one given -e SHA=): reads the tar, appends "<sha> <job>" to ran.log and
#                   its image to checks-images.log, and exits 1 when the tree has a file named
#                   FAIL.<job>
#   run, review     (the local-ci-review image): appends the sha to reviewed.log, keeps the
#                   changed-file list, and answers as the review container does
#   run -i, other   (the package fetch): reads its stdin
cat >"$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
sub="$1"
shift
case "$sub" in
  image)
    [ "$1" = inspect ] || exit 0
    printf 'sha256:%s\n' "$(printf '%s %s' "${!#}" "${FAKE_IMAGE_SALT:-}" | git hash-object --stdin)" ;;
  run)
    job="" sha="" interactive=0 detach=0 review=0
    for a in "$@"; do
      case "$a" in
        local-ci.job=*) job="${a#local-ci.job=}" ;;
        SHA=*) sha="${a#SHA=}" ;;
        -i) interactive=1 ;;
        -d) detach=1 ;;
        local-ci-review) review=1 ;;
      esac
    done
    if [ "$review" = 1 ]; then
      d="$(mktemp -d)"
      tar -xf - -C "$d"
      echo "$sha" >>"$FAKE_STATE/reviewed.log"
      cp "$d/files.txt" "$FAKE_STATE/review-files.txt"
      rm -rf "$d"
      if [ "${FAKE_REVIEW_BLOCKING:-}" = 1 ]; then
        f='[{"file":"x","line":1,"severity":"blocking","summary":"fake","failure_scenario":"f","fix":"f"}]'
      else
        f='[]'
      fi
      jq -nc --argjson f "$f" '{structured_output: {findings: $f, rules_read: [], summary: "fake review"}, num_turns: 1, total_cost_usd: 0}'
    elif [ -n "$sha" ]; then
      d="$(mktemp -d)"
      tar -xf - -C "$d"
      echo "$sha $job" >>"$FAKE_STATE/ran.log"
      echo "${!#}" >>"$FAKE_STATE/checks-images.log"
      bad="$(find "$d/tree" -name "FAIL.$job" | head -1)"
      rm -rf "$d"
      echo "fake checks for $job"
      [ -z "$bad" ] || exit 1
    elif [ "$interactive" = 1 ]; then
      cat >/dev/null
    elif [ "$detach" = 1 ]; then
      echo fake-container
    fi ;;
  *) ;;
esac
FAKE
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
export LOCAL_CI_CLAUDE_TOKEN=fake LOCAL_CI_SHARED="$SHARED"

# --- the consumer -------------------------------------------------------------------------------
# Four jobs, the reusable ones first, so a run that skips a job also shifts the ones after it:
#   back   inline, inputs: [backend/]
#   web    node-pnpm-ci, inputs: [frontend/, package.json, pnpm-lock.yaml], after: scripts/after.sh
#   cmp    inline, inputs: [backend], base: true
#   plain  inline, no inputs: runs every time, as before
REPO="$WORK/repo"
mkdir -p "$REPO/.github/workflows" "$REPO/backend" "$REPO/frontend" "$REPO/scripts"
cd "$REPO"
git init -q -b main
cat >.github/workflows/ci.yml <<'EOF'
on: [push]
jobs:
  back:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./backend/check.sh
  web:
    uses: tinbee/ci-workflows/.github/workflows/node-pnpm-ci.yml@v1
  cmp:
    runs-on: ubuntu-latest
    steps:
      - run: ./backend/compare.sh
  plain:
    runs-on: ubuntu-latest
    steps:
      - run: echo plain
EOF
LOCAL_CI_YML='jobs:
  back: { inputs: [backend/] }
  web: { inputs: [frontend/, package.json, pnpm-lock.yaml], after: scripts/after.sh }
  cmp: { inputs: [backend], base: true }
  plain: {}
'
printf '%s' "$LOCAL_CI_YML" >.local-ci.yml
echo '{"name":"consumer","packageManager":"pnpm@10.0.0"}' >package.json
echo 'lockfileVersion: 9.0' >pnpm-lock.yaml
echo 22 >.nvmrc
echo one >backend/main.txt
echo one >frontend/app.txt
echo one >other.txt
echo 'echo after' >scripts/after.sh
git add -A && git commit -qm root
git checkout -qb feat

RESULTS="$(cd "$(git rev-parse --git-common-dir)" && pwd)/local-ci"
FAILED=0
PASSED=0
ok() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL: $*" >&2
}

# change <message> <file> [<content>]: commit one change on the current branch; sets SHA.
# The content defaults to something new each time.
n=0
change() {
  n=$((n + 1))
  mkdir -p "$(dirname "$2")"
  if [ "${3+set}" = set ]; then printf '%s\n' "$3" >"$2"; else echo "change $n" >>"$2"; fi
  git add -A && git commit -qm "$1"
  SHA="$(git rev-parse HEAD)"
}

# lci [<env>...] -- [<run.sh args>...]: run.sh; RC is its exit, LOG its output.
LOG="$WORK/run.log"
lci() {
  local envs=()
  while [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  RC=0
  env ${envs[@]+"${envs[@]}"} bash "$SHARED/local-ci/run.sh" "$@" >"$LOG" 2>&1 || RC=$?
}
# run_on <sha> [<env>...]: the usual run, against main.
run_on() {
  local s="$1"
  shift
  lci "$@" -- --base main "$s"
}

result() { jq -c "$2" "$RESULTS/$1/result.json"; }
expect_rc() { # <what> <want>
  if [ "$RC" -eq "$2" ]; then ok; else
    fail "$1: exit $RC, wanted $2"
    sed 's/^/    /' "$LOG" >&2
  fi
}
is() { # <what> <got> <want>
  if [ "$2" = "$3" ]; then ok; else fail "$1: got $2, wanted $3"; fi
}
ran() { grep -qx "$1 $2" "$FAKE_STATE/ran.log"; }
expect_ran() { # <what> <sha> <job>: its checks ran, and the result records a run, not a reuse
  if ran "$2" "$3"; then ok; else fail "$1: $3 did not run on ${2:0:12}"; fi
  is "$1: $3 is recorded as run" "$(result "$2" ".checks.jobs.$3 | has(\"exit\") and (has(\"reused_from\") | not)")" true
}
expect_reused() { # <what> <sha> <job> <from sha>
  if ran "$2" "$3"; then fail "$1: $3 ran on ${2:0:12}"; else ok; fi
  is "$1: $3's entry" "$(result "$2" ".checks.jobs.$3 | {exit, seconds, reused_from}")" \
    "{\"exit\":0,\"seconds\":0,\"reused_from\":\"$4\"}"
}

# --- inputs: is validated where the config is read ----------------------------------------------
git checkout -q -b bad main
refused() { # <what> <.local-ci.yml> <part of the message>
  printf '%s' "$2" >.local-ci.yml
  git add -A && git commit -qm "bad: $1"
  lci -- --base main HEAD
  if [ "$RC" -eq 3 ] && grep -qF -- "$3" "$LOG"; then ok; else
    fail "refuses $1: exit $RC, wanted 3 with '$3'"
    sed 's/^/    /' "$LOG" >&2
  fi
}
jobs_with() { # <back's settings>: the consumer's config with back's replaced
  printf 'jobs:\n  back: %s\n  web: {}\n  cmp: {}\n  plain: {}\n' "$1"
}
refused "an absolute path" "$(jobs_with '{ inputs: [/etc] }')" "jobs.back.inputs entry '/etc'"
refused "a .. component" "$(jobs_with '{ inputs: [backend/../frontend] }')" "leaves the repository"
refused "a leading .." "$(jobs_with '{ inputs: [../x] }')" "jobs.back.inputs entry '../x'"
refused "a glob" "$(jobs_with '{ inputs: ["backend/*.go"] }')" "jobs.back.inputs entry 'backend/*.go'"
refused "the whole tree" "$(jobs_with '{ inputs: [.] }')" "must name a path inside the repository"
refused "a ./ prefix" "$(jobs_with '{ inputs: [./backend] }')" "must name a path inside the repository"
refused "an empty component" "$(jobs_with '{ inputs: [backend//x] }')" "must name a path inside the repository"
refused "an empty list" "$(jobs_with '{ inputs: [] }')" "jobs.back.inputs must be a non-empty list"
refused "a string" "$(jobs_with '{ inputs: backend/ }')" "jobs.back.inputs must be a non-empty list"
refused "a non-string entry" "$(jobs_with '{ inputs: [1] }')" "jobs.back.inputs must be a non-empty list"
refused "inputs with skip" "$(jobs_with '{ skip: CI only, inputs: [backend/] }')" "takes no other settings"
refused "inputs with skip_inputs" \
  "$(printf 'jobs:\n  back: {}\n  web: { inputs: [frontend/], skip_inputs: { test_command: no } }\n  cmp: {}\n  plain: {}\n')" \
  "a job with skip_inputs always runs"
refused "a top-level inputs beside jobs:" "$(printf 'inputs: [backend/]\n%s' "$(jobs_with '{}')")" "has jobs: and a top-level inputs"
is "nothing ran for a refused config" "$(wc -l <"$FAKE_STATE/ran.log" | tr -d ' ')" 0
git checkout -q feat

# --- reuse ---------------------------------------------------------------------------------------
echo two >frontend/app.txt
change "a: both" backend/main.txt
A="$SHA"
run_on "$A"
expect_rc "first run" 0
for j in back web cmp plain; do expect_ran "first run" "$A" "$j"; done
is "a job with inputs records its fingerprint" "$(result "$A" '.checks.jobs.back.fingerprint | test("^[0-9a-f]{40}$")')" true
is "a job without inputs records none" "$(result "$A" '.checks.jobs.plain | has("fingerprint")')" false
is "the same inputs, another job: another fingerprint" \
  "$(result "$A" '.checks.jobs.back.fingerprint != .checks.jobs.cmp.fingerprint')" true
# By the id the fingerprint names, not by a tag another run could rebuild meanwhile.
is "the checks run by image id" "$(grep -cv '^sha256:' "$FAKE_STATE/checks-images.log")" 0

change "b: frontend only" frontend/app.txt
B="$SHA"
run_on "$B"
expect_rc "frontend change" 0
expect_reused "frontend change" "$B" back "$A"
expect_reused "frontend change" "$B" cmp "$A"
expect_ran "frontend change" "$B" web
expect_ran "no inputs: runs as before" "$B" plain
is "a reused job keeps its fingerprint" "$(result "$B" '.checks.jobs.back.fingerprint')" "$(result "$A" '.checks.jobs.back.fingerprint')"
is "status with reused jobs" "$(result "$B" .status)" '"pass"'
# The review is of the whole diff, reused jobs or not: backend/main.txt changed on the branch.
if grep -qx "$B" "$FAKE_STATE/reviewed.log" && grep -qx backend/main.txt "$FAKE_STATE/review-files.txt"; then ok; else
  fail "the review of a run with reused jobs is not of the whole diff"
fi
# The pre-push hook passes a tip whose run passed with reused jobs.
RC=0
printf 'refs/heads/feat %s refs/heads/feat %s\n' "$B" 0000000000000000000000000000000000000000 \
  | bash "$SHARED/local-ci/run.sh" pre-push origin url >"$LOG" 2>&1 || RC=$?
expect_rc "pre-push of a pass with reused jobs" 0

change "c: backend" backend/main.txt
C="$SHA"
run_on "$C"
expect_ran "a change inside an input" "$C" back
expect_ran "a change inside an input" "$C" cmp
expect_reused "a change outside its inputs" "$C" web "$B"

change "d: .local-ci.yml" .local-ci.yml "$LOCAL_CI_YML# a comment"
D="$SHA"
run_on "$D"
for j in back web cmp; do expect_ran ".local-ci.yml changed" "$D" "$j"; done

change "e: ci.yml" .github/workflows/ci.yml "$(cat .github/workflows/ci.yml)
# a comment"
E="$SHA"
run_on "$E"
for j in back web cmp; do expect_ran "ci.yml changed" "$E" "$j"; done

change "f: the after script" scripts/after.sh
F="$SHA"
run_on "$F"
expect_ran "the after script changed" "$F" web
expect_reused "the after script changed" "$F" back "$E"

change "g: elsewhere" other.txt
G="$SHA"
run_on "$G" LOCAL_CI_NO_REUSE=1
expect_rc "LOCAL_CI_NO_REUSE=1" 0
for j in back web cmp plain; do expect_ran "LOCAL_CI_NO_REUSE=1" "$G" "$j"; done
is "LOCAL_CI_NO_REUSE=1 still records the fingerprint" "$(result "$G" '.checks.jobs.back.fingerprint')" "$(result "$F" '.checks.jobs.back.fingerprint')"

# Sequentially, through the same code: a reused job ahead of run ones must not shift them.
change "h: sequential" frontend/app.txt
H="$SHA"
run_on "$H" LOCAL_CI_PARALLEL=0
expect_rc "sequential" 0
expect_reused "sequential" "$H" back "$G"
expect_ran "sequential" "$H" web
expect_ran "sequential" "$H" plain
is "sequential: every job is recorded" "$(result "$H" '.checks.jobs | keys')" '["back","cmp","plain","web"]'

# What defines the run, outside the commit: the ci-workflows files and the checks image.
change "i: runner" other.txt
I="$SHA"
echo "# changed" >>"$SHARED/local-ci/README.md"
run_on "$I"
expect_ran "the ci-workflows files changed" "$I" back
change "j: image" other.txt
J="$SHA"
export FAKE_IMAGE_SALT=new
run_on "$J"
expect_ran "the checks image changed" "$J" back
change "k: neither" other.txt
K="$SHA"
run_on "$K"
expect_reused "neither changed" "$K" back "$J"

# A listed path that does not exist is part of the fingerprint: creating it runs the job.
LOCAL_CI_YML="$(sed 's|back: { inputs: \[backend/\] }|back: { inputs: [backend/, sdk/] }|' <<<"$LOCAL_CI_YML")"
grep -qF 'inputs: [backend/, sdk/]' <<<"$LOCAL_CI_YML" || { echo "selftest: could not edit the config" >&2; exit 2; }
change "l: list sdk/" .local-ci.yml "$LOCAL_CI_YML"
L="$SHA"
run_on "$L"
expect_rc "sdk/ listed" 0
expect_ran "inputs gained a path" "$L" back
change "m: elsewhere" other.txt
M="$SHA"
run_on "$M"
expect_reused "a missing input still missing" "$M" back "$L"
if grep -qF "inputs entry 'sdk' is not in ${M:0:12}" "$LOG"; then ok; else fail "a missing input is not named"; fi
change "n: create sdk/" sdk/x.txt
N="$SHA"
run_on "$N"
expect_ran "a missing input created" "$N" back
change "o: elsewhere" other.txt
O="$SHA"
run_on "$O"
expect_reused "after creating it" "$O" back "$N"

# base: true: the job also reads the base, so another base runs it; back does not read it.
change "p: elsewhere" other.txt
P="$SHA"
lci -- --base "$O" "$P"
expect_ran "cmp against another base" "$P" cmp
# N, which ran it: O reused N's pass, and a reuse always names the commit that ran the job.
expect_reused "back against another base" "$P" back "$N"

# --- only a pass is reused -----------------------------------------------------------------------
# The job failed: never reused, however often its inputs come back.
change "q: back fails" backend/FAIL.back
Q="$SHA"
run_on "$Q"
expect_rc "a failing job" 1
is "a failing job's status" "$(result "$Q" .status)" '"fail-checks"'
change "r: frontend only" frontend/app.txt
R="$SHA"
run_on "$R"
expect_rc "a failure is not reused" 1
expect_ran "a failure is not reused" "$R" back
git rm -q backend/FAIL.back && git commit -qm "s: back fixed"
S="$(git rev-parse HEAD)"
run_on "$S"
expect_reused "back to the inputs of the last pass that ran it" "$S" back "$N"

# The job passed, in a run that did not: another job failed.
touch frontend/FAIL.web
change "t: backend, and web fails" backend/main.txt
T="$SHA"
run_on "$T"
expect_rc "web fails" 1
is "back passed in a failed run" "$(result "$T" '.checks.jobs.back.exit')" 0
git rm -q frontend/FAIL.web && git commit -qm "u: web fixed"
U="$(git rev-parse HEAD)"
run_on "$U"
expect_rc "web fixed" 0
expect_ran "not from a fail-checks run" "$U" back

# The job passed, and the review blocked: fail-review, then accepted.
change "v: backend" backend/main.txt
V="$SHA"
run_on "$V" FAKE_REVIEW_BLOCKING=1
expect_rc "blocking review" 2
change "w: frontend only" frontend/app.txt
W="$SHA"
run_on "$W" FAKE_REVIEW_BLOCKING=1
expect_rc "blocking review again" 2
expect_ran "not from a fail-review run" "$W" back
lci -- accept "$V" selftest
expect_rc "accept V" 0
lci -- accept "$W" selftest
expect_rc "accept W" 0
change "x: frontend only" frontend/app.txt
X="$SHA"
run_on "$X"
expect_ran "not from an accepted run" "$X" back
change "y: frontend only" frontend/app.txt
Y="$SHA"
run_on "$Y"
expect_reused "from the pass" "$Y" back "$X"

# Within a pass, an entry that is not a run of its own that passed. Each is planted in X's
# result, the only pass with this fingerprint that ran back (Y reused it, and is removed); the
# run each provokes is removed again after.
rm -rf "${RESULTS:?}/$Y"
xres="$RESULTS/$X/result.json"
cp "$xres" "$WORK/x.json"
planted() { # <what> <jq update of X's result>
  jq -c "$2" "$WORK/x.json" >"$xres"
  change "z: $1" frontend/app.txt
  run_on "$SHA"
  expect_ran "not from an entry with $1" "$SHA" back
  rm -rf "${RESULTS:?}/$SHA"
  cp "$WORK/x.json" "$xres"
}
zero=0000000000000000000000000000000000000000
planted "skipped_inputs" '.checks.jobs.back += {skipped_inputs: {test_command: "planted"}}'
planted "an error" '.checks.jobs.back += {error: "could not run"} | del(.checks.jobs.back.exit)'
planted "an error and exit 0" '.checks.jobs.back += {error: "could not run"}'
planted "reused_from" ".checks.jobs.back += {reused_from: \"$zero\"}"
planted "a non-zero exit" '.checks.jobs.back.exit = 1'
planted "a skip and exit 0" '.checks.jobs.back += {skipped: "planted"}'
# The fingerprint is still in the file, under another job, so only the comparison excludes it.
planted "another fingerprint" ".checks.jobs.web.fingerprint = .checks.jobs.back.fingerprint | .checks.jobs.back.fingerprint = \"$zero\""
# Unplanted, the same kind of commit reuses X: the cases above differ from it in the entry alone.
change "z: control" frontend/app.txt
run_on "$SHA"
expect_reused "the control" "$SHA" back "$X"
# Nor is a commit's own earlier result reused: re-running X runs back again.
run_on "$X"
if [ "$(grep -cx "$X back" "$FAKE_STATE/ran.log")" -eq 2 ]; then ok; else fail "re-running X reused its own pass"; fi

# A job none of whose inputs exist (a misspelt list) fingerprints nothing it reads: never reused.
LOCAL_CI_YML="$(sed 's|back: { inputs: \[backend/, sdk/\] }|back: { inputs: [backnd/] }|' <<<"$LOCAL_CI_YML")"
grep -qF 'inputs: [backnd/]' <<<"$LOCAL_CI_YML" || { echo "selftest: could not edit the config" >&2; exit 2; }
change "all inputs missing" .local-ci.yml "$LOCAL_CI_YML"
run_on "$SHA"
expect_ran "no input exists" "$SHA" back
change "all inputs missing, again" other.txt
run_on "$SHA"
expect_rc "no input exists, again" 0
expect_ran "no input exists, again" "$SHA" back

echo "selftest: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
