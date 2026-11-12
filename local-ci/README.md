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

While a run is going, `state.json` beside the result says where it is: `phase` (`preparing`,
`modules`, `images`, `checks`, `review`, then `done` with `exit` and `finished`), plus the
run's `pid` and `ns`, the label on every container and network it starts, and, from
`modules` to `checks`, the ci.yml `job` being worked on. To cancel a run: TERM the pid
and `docker rm -f` the containers labelled `local-ci.run=<ns>` (bash defers the TERM until the
running command ends; removing the containers ends it). confleet's Local CI page reads these.

## What runs

**Checks: each go-ci.yml job, as the commit's own ci.yml calls it.** `go-checks.sh` runs
go-ci's steps in go-ci's order (generate + drift check, lint, golangci-lint, gofmt, tidy, build, test
with `-count=1`, govulncheck, post), with the inputs the commit's `ci.yml` passes over
go-ci.yml's own defaults at `v1`. Then the job's `after` script, for what its `ci.yml` runs
outside go-ci. One job at a time, in ci.yml's order, each in its own container with its own
services and network, stopping at the first that fails. A job's services share its checks
container's network namespace, so they are on `127.0.0.1` as a GitHub job's are, and also
reachable by their names. `result.json` has each job under
`checks.jobs`, as `{exit, seconds}` or `{skipped: <reason>}`. Not run locally:

- **`pre_command`**: CI's machine setup (woahbar and Foliot start Postgres with it).
  `.local-ci.yml` `services` replace it.
- **Jobs that call another workflow, or are written inline in ci.yml.** With `jobs:`, each is
  listed as `skip: <reason>`, so the result says what a pass does not cover. Where an inline
  job can run in a go-ci job's container, put its commands in a script that CI and `after`
  both call, so the two cannot drift (instastack's `scripts/integration-test.sh`).

**Review: the same prompt as the `claude-review` label.** `review/core.md` with the
structured ending, the shared `review-rules/` and the caller's `project_context` (see
`../review/README.md`).

## What each container can reach

| | checks | review |
| --- | --- | --- |
| code | the commit (a git bundle) | the commit and its diff |
| network | `--internal`, one per job; a proxy allows `checks-allow.txt` (buf.build for remote buf plugins, vuln.go.dev for govulncheck) | `--internal`; a proxy allows `api.anthropic.com` |
| modules | pre-fetched **on the host** with its own credentials, mounted read-only as `GOPROXY=file://`, and nothing else: every module in the commit (each `go.mod`), and each `go run`/`go install <path>@<version>` in the job's go-ci commands and `after` script, which must name an exact version | none |
| credentials | none | the Claude token only |
| tools | Go at go.mod's version (its `toolchain` line if it has one, else its `go` line), and buf, sqlc, golangci-lint, govulncheck as ci.yml asks | Read/Glob/Grep; none of the commit's own Claude config |

No public module proxy is reachable from the checks container: proxy.golang.org fetches any
path it is asked for from wherever that path points, so code in the commit could send data
out through it, and its downloads redirect to storage.googleapis.com, which is any bucket.

The token (`LOCAL_CI_CLAUDE_TOKEN`, a `claude setup-token` token) reaches only the review
container, as `CLAUDE_CODE_OAUTH_TOKEN`. Never export it under that name on the host: it
replaces the login of every interactive `claude`.

## Adopting it in a repo

1. Copy `consumer-local-ci.sh` to `scripts/local-ci.sh`. It finds a ci-workflows checkout
   (`../ci-workflows`, `~/workspace/tinbee/ci-workflows`, or `LOCAL_CI_RULES_REPO`),
   refreshes `v1`, and runs this directory from it.
2. Add `.local-ci.yml` at the root, with every ci.yml job under `jobs:`:

   ```yaml
   jobs:
     go:                        # a ci.yml job that calls go-ci.yml ({} or empty: no settings)
       services:                # at 127.0.0.1, as in CI, and by name; one port each
         postgres:
           image: postgres:17
           env: { POSTGRES_USER: app, POSTGRES_PASSWORD: app, POSTGRES_DB: app_test }
           ready: pg_isready -h 127.0.0.1 -U app -d app_test   # docker exec'd until it passes, 60s
       env:                     # for the checks; wins over ci.yml's env_json
         APP_TEST_DATABASE_URL: postgres://app:app@postgres:5432/app_test?sslmode=disable
       after: scripts/integration-test.sh   # optional, from the repo root
     web:
       skip: no node-pnpm-ci.yml mirror yet   # stays CI-only; the reason goes in the result
   ```

   A ci.yml job missing from `jobs:`, or a `jobs:` entry ci.yml does not have, stops the run,
   as does a `jobs:` whose every job is skipped. The first shape, with `ci_job`, `services`,
   `env` and `after` at the top level, still works: it runs that one go-ci job and does not
   look at the others.

3. `make local-ci` → `scripts/local-ci.sh`. For the hook: `scripts/local-ci.sh install-hook`,
   or, in a repo that versions its hooks with `core.hooksPath` (instastack's `.githooks`),
   a committed `pre-push` that runs `scripts/local-ci.sh pre-push "$@"`.

Only go-ci.yml callers for now; node-pnpm-ci.yml is the next shape to mirror when a pnpm repo
adopts this.
