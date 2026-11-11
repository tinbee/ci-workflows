# local-ci

A repo's CI checks, then the cold-context Claude review, run on a commit **before it is
pushed**, each in a throwaway container. GitHub CI still runs on the push and stays the merge
gate. This exists so review rounds happen before CI, instead of each round waiting on a CI
run and a label.

```sh
make local-ci                                        # checks + review of HEAD against origin/main
scripts/local-ci.sh accept <sha> "<why it is wrong>"  # override a fail-review
```

Exit `0` pass, `1` checks failed, `2` blocking findings, `3` could not run. The result, with
findings, timings and the review's cost, is in `$(git rev-parse --git-common-dir)/local-ci/<sha>/result.json`.
A pre-push hook refuses a branch whose tip has not passed or been accepted
(`git push --no-verify` skips it).

## What runs

**Checks: go-ci.yml, as the commit's own ci.yml calls it.** `go-checks.sh` runs go-ci's
steps in go-ci's order (generate + drift check, lint, golangci-lint, gofmt, build, test with
`-count=1`, govulncheck, post), with the inputs the commit's `ci.yml` passes over go-ci.yml's
own defaults at `v1`. Then the repo's `after` script, for what its `ci.yml` runs outside
go-ci. Not run locally:

- **`pre_command`**: CI's machine setup (woahbar starts Postgres with it).
  `.local-ci.yml` `services` replace it.
- **Jobs a repo writes inline in ci.yml**, unless its `after` script covers them. Put the
  job's commands in a script that CI and `after` both call, so the two cannot drift
  (instastack's `scripts/integration-test.sh`).

**Review: the same prompt as the `claude-review` label.** `review/core.md` with the
structured ending, the shared `review-rules/` and the caller's `project_context` (see
`../review/README.md`).

## What each container can reach

| | checks | review |
| --- | --- | --- |
| code | the commit (a git bundle) | the commit and its diff |
| network | `--internal`; a proxy allows `checks-allow.txt` (buf.build for remote buf plugins, vuln.go.dev for govulncheck) | `--internal`; a proxy allows `api.anthropic.com` |
| modules | pre-fetched **on the host** with its own credentials, mounted read-only as `GOPROXY=file://`, checked against go.sum | none |
| credentials | none | the Claude token only |
| tools | Read/Glob/Grep only, none of the commit's own Claude config | |

The token (`LOCAL_CI_CLAUDE_TOKEN`, a `claude setup-token` token) reaches only the review
container, as `CLAUDE_CODE_OAUTH_TOKEN`. Never export it under that name on the host: it
replaces the login of every interactive `claude`.

## Adopting it in a repo

1. Copy `consumer-local-ci.sh` to `scripts/local-ci.sh`. It finds a ci-workflows checkout
   (`../ci-workflows`, `~/workspace/tinbee/ci-workflows`, or `LOCAL_CI_RULES_REPO`),
   refreshes `v1`, and runs this directory from it.
2. Add `.local-ci.yml` at the root:

   ```yaml
   ci_job: ci                 # the ci.yml job that calls go-ci.yml (found if omitted)
   services:                  # on the checks network, reachable by name
     postgres:
       image: postgres:17
       env: { POSTGRES_USER: app, POSTGRES_PASSWORD: app, POSTGRES_DB: app_test }
       ready: pg_isready -h 127.0.0.1 -U app -d app_test   # docker exec'd until it passes, 60s
   env:                       # for the checks; wins over ci.yml's env_json
     APP_TEST_DATABASE_URL: postgres://app:app@postgres:5432/app_test?sslmode=disable
   after: scripts/integration-test.sh   # optional, from the repo root
   ```

3. `make local-ci` → `scripts/local-ci.sh`. For the hook: `scripts/local-ci.sh install-hook`,
   or, in a repo that versions its hooks with `core.hooksPath` (instastack's `.githooks`),
   a committed `pre-push` that runs `scripts/local-ci.sh pre-push "$@"`.

Only go-ci.yml callers for now; node-pnpm-ci.yml is the next shape to mirror when a pnpm repo
adopts this.
