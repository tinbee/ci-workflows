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
Each review the model answered also appends one line to `local-ci/costs.jsonl` beside the
results (`created`, `sha`, `status`, `model`, `effort`, `seconds`, `cost_usd`, the API price
the Claude CLI reports): the cost history, which a re-run replacing `result.json` or a
deleted result does not lose.
A pre-push hook refuses a branch whose tip has not passed or been accepted
(`git push --no-verify` skips it).

While a run is going, `state.json` beside the result says where it is: `phase` (`preparing`,
`modules`, `images`, `checks`, `review`, then `done` with `exit` and `finished`), plus the
run's `pid` and `ns`, the label on every container and network it starts, and, from
`modules` to `checks`, the ci.yml `job` being worked on. `branch` is the branch the commit
was on when the run started (`<branch>~<n>` behind its tip), kept for after a squash-merge
deletes it and no ref names the commit any more. To cancel a run: TERM the pid
and `docker rm -f` the containers labelled `local-ci.run=<ns>` (bash defers the TERM until the
running command ends; removing the containers ends it). confleet's Local CI page reads these.

## What runs

**Checks: every ci.yml job, as the commit's own ci.yml defines it.** A go-ci.yml or node-pnpm-ci.yml job runs its workflow's steps, with
the inputs it passes over the workflow's own defaults at `v1`:

- `go-checks.sh`: go-ci's steps in go-ci's order (generate + drift check, lint, golangci-lint,
  gofmt, tidy, build, test with `-count=1`, govulncheck, post).
- `node-checks.sh`: node-pnpm-ci's steps in its order (install, pre-check, format check, lint,
  typecheck, build, test), with Node at the commit's `node_version_file` (else `node_version`),
  pnpm at `package.json`'s `packageManager`, and `CI=true`. Not `coverage_command`, which CI
  runs only on a push to the default branch, nor the turbo remote cache.

- `inline-checks.sh`: a job ci.yml writes inline runs its own `run:` steps, in order, each in its
  `working-directory`, with the job's env, then the step's, then `.local-ci.yml` `env` over both,
  and under GitHub's command line for its `shell` (`bash -e` unnamed, `bash -eo pipefail` for
  `bash`, `sh -e`). Its setup actions choose the image: `actions/checkout`,
  `pnpm/action-setup` (pnpm from `packageManager`), `actions/setup-node` and `actions/setup-go`
  (their version files or versions). Any other action, an `if:`, a `container:` or a matrix
  stops the run naming it, as do services ci.yml gives the job that `.local-ci.yml` does not.

Then the job's `after` script, for what its `ci.yml` runs outside the workflow. The jobs are
prepared one at a time (image, modules, packages), then run side by side, each in its own
container with its own services and network, and the run waits for all of them, as CI does, so
one job's failure does not hide another's. `LOCAL_CI_PARALLEL=0`, or a bash older than 5.1, runs
them one at a time instead. A job whose services or container could not start is recorded as
`{error: "could not run"}` and the run exits 3. A job's services share its checks
container's network namespace, so they are on `127.0.0.1` as a GitHub job's are, and also
reachable by their names. `result.json` has each job under
`checks.jobs`, as `{exit, seconds}` or `{skipped: <reason>}`. Not run locally:

- **`pre_command`**: CI's machine setup (woahbar and Foliot start Postgres with it).
  `.local-ci.yml` `services` replace it.
- **Jobs that call any other workflow, or that an inline job's limits above rule out.** With
  `jobs:`, each is listed as `skip: <reason>`, so the result says what a pass does not cover. Where an inline
  job can run in a go-ci job's container, put its commands in a script that CI and `after`
  both call, so the two cannot drift (instastack's `scripts/integration-test.sh`).

**Review: the same prompt as the `claude-review` label.** `review/core.md` with the
structured ending, the shared `review-rules/` and the caller's `project_context` (see
`../review/README.md`).

## What each container can reach

| | checks | review |
| --- | --- | --- |
| code | the commit (a git bundle) | the commit and its diff |
| network | `--internal`, one per job; a proxy allows `checks-allow.txt` (vuln.go.dev for govulncheck, binaries.prisma.sh for Prisma's engines, fonts.googleapis.com and fonts.gstatic.com for `next/font/google`) | `--internal`; a proxy allows `api.anthropic.com` |
| Go modules | pre-fetched **on the host** with its own credentials, mounted read-only as `GOPROXY=file://`, and nothing else: every module in the commit (each `go.mod`), and each `go run`/`go install <path>@<version>` in the job's go-ci commands and `after` script, which must name an exact version | none |
| npm packages | a copy, made for this run, of the repository's package caches (the Docker volume `local-ci-pnpm-<repo>`: the pnpm store, and for an inline job an npm cache too); every install is offline | none |
| credentials | none | the Claude token only |
| tools | Go at go.mod's version (its `toolchain` line if it has one, else its `go` line), and buf, sqlc, golangci-lint, govulncheck as ci.yml asks | Read/Glob/Grep; none of the commit's own Claude config |

Every host in `checks-allow.txt` serves fixed files: code in the commit can read from them,
but cannot pass data through them to anyone. A host that fetches on a caller's behalf or
accepts uploads does not belong in that file. That ruled out `buf.build`, which takes a `buf
push` from anyone with a token: buf's remote plugins run on it, so a repo using them needs
local plugins instead, pinned as Go tools (`local: ["go", "tool", "protoc-gen-go"]`, with
`go get -tool ...@vX`), which is also the only way their version is fixed at all.

No public module proxy or package registry is reachable from the checks container:
proxy.golang.org fetches any path it is asked for from wherever that path points, and its
downloads redirect to storage.googleapis.com, which is any bucket; the npm registry accepts a
publish from anyone with a token. Code in the commit could send data out through any of them.

npm packages come from a **fetch container** instead, the only one that reaches
`registry.npmjs.org` (`npm-allow.txt`, and nothing else). It is given the commit's
`package.json` files, `pnpm-lock.yaml`, `pnpm-workspace.yaml` and `package-lock.json` files,
none executable, no other file (not `.npmrc`, which can name programs for pnpm to run). It runs
`pnpm install --frozen-lockfile --ignore-scripts --ignore-pnpmfile` into the store volume, and,
for an inline job, `npm ci --ignore-scripts` for each `package-lock.json` and `npm cache add`
for the registry dependencies of every publishable (named, not private) package, which a
packed tarball of it brings and npm resolves from their ranges. None of the commit's code or
its dependencies' install scripts runs there. The
checks get a copy because pnpm opens its store's index for writing: a read-only mount does not
install, and a shared writable store would let one commit change the packages a later run
installs. The store volume grows with every lockfile it has seen; `docker volume rm
local-ci-pnpm-<repo>` starts it again (the next run fetches everything).

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
       env:                     # for the checks; wins over ci.yml's env_json, and must set any
                                # key whose env_json value is a ${{ }} expression (vars.X)
         APP_TEST_DATABASE_URL: postgres://app:app@postgres:5432/app_test?sslmode=disable
       after: scripts/integration-test.sh   # optional, from the repo root
     web: {}                    # a node-pnpm-ci.yml job; the same settings apply
     smoke:                     # an inline job: its steps run; services and env as above
     e2e:
       skip: needs a browser    # stays CI-only; the reason goes in the result
   ```

   A ci.yml job missing from `jobs:`, or a `jobs:` entry ci.yml does not have, stops the run,
   as does a `jobs:` whose every job is skipped. The first shape, with `ci_job`, `services`,
   `env` and `after` at the top level, still works: it runs that one go-ci job and does not
   look at the others.

3. `make local-ci` → `scripts/local-ci.sh`. For the hook: `scripts/local-ci.sh install-hook`,
   or, in a repo that versions its hooks with `core.hooksPath` (instastack's `.githooks`),
   a committed `pre-push` that runs `scripts/local-ci.sh pre-push "$@"`.

A node-pnpm-ci.yml job needs the consumer script from v1.28.0 on, which extracts that workflow
too; an older copy stops with a message saying to update it.
