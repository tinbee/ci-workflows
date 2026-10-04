# ci-workflows

Reusable GitHub Actions workflows for `tinbee` and other repos. Single source of truth for action versions and CI/CD step shapes — bump an action here once, every consumer picks it up on their next run.

Public so any org's repo can consume it. Reusable workflows in private repos can only be called from the same org; making this public is the standard pattern for cross-org sharing.

## Available workflows

### `deploy-s3-cloudfront.yml`

Deploy a static site to AWS S3 + CloudFront. Defaults to the **SPA pattern** (Vite/Astro/Next-style): two-pass S3 sync with hashed `assets/*` getting `max-age=31536000, immutable` and everything else getting `max-age=0, must-revalidate`, plus targeted CloudFront invalidation of `/` and `/index.html` only (hashed assets never need invalidating). Legacy static sites with root-served HTML/other files (cal-style) override these defaults.

#### SPA caller (recommended — Vite/Astro/Next)

```yaml
name: Deploy web
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-web-${{ github.ref }}
  cancel-in-progress: true

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    uses: tinbee/ci-workflows/.github/workflows/deploy-s3-cloudfront.yml@v1
    with:
      aws_region: ${{ vars.AWS_REGION }}
      build_command: |
        pnpm install --frozen-lockfile --filter @yourapp/web...
        pnpm --filter @yourapp/web build
      source_dir: apps/web/dist/
      env_json: |
        {
          "VITE_API_URL": "${{ vars.VITE_API_URL }}",
          "VITE_PUBLIC_KEY": "${{ vars.VITE_PUBLIC_KEY }}"
        }
    secrets:
      role_to_assume: ${{ secrets.AWS_CLOUDFRONT_ROLE_TO_ASSUME }}
      s3_bucket: ${{ secrets.AWS_S3_BUCKET }}
      cloudfront_distribution: ${{ secrets.AWS_CLOUDFRONT_DISTRIBUTION_ID }}
```

#### Legacy static-site caller (cal-style — root-served `.html`, `.ics`, etc.)

```yaml
jobs:
  deploy:
    uses: tinbee/ci-workflows/.github/workflows/deploy-s3-cloudfront.yml@v1
    with:
      aws_region: ${{ vars.AWS_REGION }}
      source_dir: "."
      setup_pnpm: false # no package.json
      cache_control_overrides: "" # disable multi-pass sync
      default_cache_control: "" # no Cache-Control header
      invalidation_paths: "/*" # invalidate everything
      sync_excludes: |
        .git/*
        .github/*
      content_type_fixups: |
        [{"ext":".ics","content_type":"text/calendar; charset=utf-8","cache_control":"public, max-age=3600"}]
    secrets: { ... }
```

#### Inputs

| Input                     | Type    | Default                                                                                 | Notes                                                                                                                                                             |
| ------------------------- | ------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `node_version`            | string  | `"24"`                                                                                  | Passed to `actions/setup-node`.                                                                                                                                   |
| `build_command`           | string  | `""`                                                                                    | Multi-line bash; skipped when empty.                                                                                                                              |
| `source_dir`              | string  | `"dist/"`                                                                               | What to sync to S3.                                                                                                                                               |
| `sync_excludes`           | string  | `""`                                                                                    | Newline-separated `--exclude` patterns (applies to every sync pass).                                                                                              |
| `cache_control_overrides` | string  | `'[{"path_pattern":"assets/*","cache_control":"public, max-age=31536000, immutable"}]'` | JSON array of per-pattern Cache-Control overrides. Each entry runs as a separate `aws s3 sync` pass before the default. Pass `""` to disable multi-pass entirely. |
| `default_cache_control`   | string  | `"public, max-age=0, must-revalidate"`                                                  | Cache-Control for files NOT matched by any override. Pass `""` to omit the header (S3 default).                                                                   |
| `content_type_fixups`     | string  | `""`                                                                                    | JSON array of per-extension Content-Type fixups. Each entry needs `ext`, `content_type`, optional `cache_control`. Runs after all sync passes.                    |
| `invalidation_paths`      | string  | `"/ /index.html"`                                                                       | Space-separated CloudFront paths. SPA-friendly default. Pass `"/*"` for legacy static sites.                                                                      |
| `env_json`                | string  | `"{}"`                                                                                  | JSON object exported to `$GITHUB_ENV` before the build step. Use for `VITE_*` / `NEXT_PUBLIC_*` build-time config.                                                |
| `aws_region`              | string  | required                                                                                | e.g. `us-east-1`. Pass via `vars.X` or hardcode — **NOT** `secrets.X` (the `with:` block forbids the secrets context).                                            |
| `setup_pnpm`              | boolean | `true`                                                                                  | Whether to set up pnpm + pnpm cache. Set to `false` for consumers without `package.json` or `packageManager` field.                                               |

#### Secrets

| Secret                    | Notes                                                                                              |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| `role_to_assume`          | IAM role ARN for OIDC. Role must trust `token.actions.githubusercontent.com` and the calling repo. |
| `s3_bucket`               | Bucket name, no `s3://` prefix.                                                                    |
| `cloudfront_distribution` | Distribution ID.                                                                                   |

#### Validation

All required inputs/secrets (`aws_region`, `role_to_assume`, `s3_bucket`, `cloudfront_distribution`) are checked **non-empty** as the first step, before any AWS call. `required: true` only guarantees the caller _passed_ a value — not that it's non-empty — so a missing `vars.AWS_REGION` (which resolves to `""`) or an unset secret fails fast here with a `::error::` annotation naming exactly what's missing, instead of a cryptic failure mid-deploy. The reusable workflow is the source of correctness; a consumer that isn't configured correctly is told precisely what to fix.

---

### `node-pnpm-ci.yml`

CI workflow for pnpm-based Node projects. Skeleton runs checkout → pnpm → Node (`.nvmrc`-driven) → install, then opinionated default steps (format / lint / typecheck / build / test). Each step is opt-out by setting its input to `""`. Pre-check slot (input `pre_check_command`) for code generation (Prisma generate, GraphQL codegen) that needs to run before typecheck.

#### Caller example

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    uses: tinbee/ci-workflows/.github/workflows/node-pnpm-ci.yml@v1
    with:
      # Opt out of any step by passing "":
      # test_command: ""
      pre_check_command: pnpm --filter @yourapp/api db:generate
      build_command: |
        pnpm --filter @yourapp/api build
        pnpm --filter @yourapp/web build
      test_command: pnpm --filter @yourapp/api test
      env_json: |
        {
          "DATABASE_URL": "postgresql://ci:ci@localhost:5432/ci",
          "VITE_API_URL": "https://ci.example",
          "VITE_PUBLIC_KEY": "ci-placeholder"
        }
```

#### Inputs

| Input                     | Type   | Default                            | Notes                                                                                                                                                                                                                  |
| ------------------------- | ------ | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `node_version_file`       | string | `".nvmrc"`                         | Single source of truth shared with local dev. Pass `""` to use `node_version` literal instead.                                                                                                                         |
| `node_version`            | string | `"24"`                             | Only used when `node_version_file` is empty.                                                                                                                                                                           |
| `install_command`         | string | `"pnpm install --frozen-lockfile"` | Empty to skip (rare).                                                                                                                                                                                                  |
| `pre_check_command`       | string | `""`                               | Codegen / schema generation. Runs after install, before format/lint/typecheck.                                                                                                                                         |
| `format_check_command`    | string | `"pnpm format:check"`              | Empty to skip.                                                                                                                                                                                                         |
| `lint_command`            | string | `"pnpm lint"`                      | Empty to skip.                                                                                                                                                                                                         |
| `typecheck_command`       | string | `"pnpm -r typecheck"`              | Empty to skip.                                                                                                                                                                                                         |
| `build_command`           | string | `"pnpm -r build"`                  | Empty to skip.                                                                                                                                                                                                         |
| `test_command`            | string | `"pnpm -r test"`                   | Empty to skip. Runs on every trigger unless superseded by a coverage run (see below).                                                                                                                                  |
| `coverage_command`        | string | `""`                               | Run **instead of** `test_command` on pushes to the default branch (post-merge). Produces coverage reports as evidence (not a gate). Empty disables coverage runs. Caller must trigger on `push` to the default branch. |
| `coverage_artifact_path`  | string | `""`                               | Multi-line glob paths uploaded as the coverage artifact (e.g. `packages/*/coverage`). Empty skips the upload. Only used during a coverage run.                                                                         |
| `coverage_artifact_name`  | string | `"coverage"`                       | Name of the uploaded coverage artifact.                                                                                                                                                                                |
| `coverage_retention_days` | number | `14`                               | Retention (days) for the coverage artifact.                                                                                                                                                                            |
| `env_json`                | string | `"{}"`                             | JSON object of env vars exported to `$GITHUB_ENV`.                                                                                                                                                                     |
| `timeout_minutes`         | number | `15`                               | Job timeout.                                                                                                                                                                                                           |
| `turbo_api`               | string | `""`                               | Turbo Remote Cache API URL (typically `vars.TURBO_API`). Empty runs without remote cache.                                                                                                                              |
| `turbo_team`              | string | `""`                               | Turbo Remote Cache team slug (typically `vars.TURBO_TEAM`).                                                                                                                                                            |

#### Secrets

| Secret        | Required | Notes                                                                                                                                                                                                                                          |
| ------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `turbo_token` | no       | Turbo Remote Cache token (`secrets.TURBO_TOKEN`). Omit to run without remote cache. Must be a secret — it can't ride in `env_json` (a `with:` input, where the secrets context is forbidden). Pair with the `turbo_api` + `turbo_team` inputs. |

The job is always named `CI` — required-status-check rulesets should reference this name.

---

### `deploy-gh-pages.yml`

Build a static/SPA site and publish it to **GitHub Pages**. Two jobs: `build` (checkout → pnpm/Node → build → upload Pages artifact) and `deploy` (`actions/deploy-pages`). pnpm-first defaults; npm consumers set `setup_pnpm: false` and override `build_command`.

The caller **must** grant the Pages permission ceiling (reusable workflows inherit caller permissions) and should set a concurrency group.

#### Caller example

```yaml
name: Deploy to GitHub Pages
on:
  push:
    branches: ["main"]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: "pages"
  cancel-in-progress: false

jobs:
  deploy:
    if: github.ref == 'refs/heads/main'
    uses: tinbee/ci-workflows/.github/workflows/deploy-gh-pages.yml@v1
    # All defaults suit a pnpm Vite SPA (build → dist/). Override as needed:
    # with:
    #   setup_pnpm: false
    #   build_command: |
    #     npm ci
    #     npm run build
    #   artifact_path: frontend/dist
```

#### Inputs

| Input           | Type    | Default                                         | Notes                                                                                            |
| --------------- | ------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `node_version`  | string  | `"24"`                                          | Passed to `actions/setup-node`.                                                                  |
| `setup_pnpm`    | boolean | `true`                                          | Set up pnpm + `cache: pnpm`. Set `false` for npm/yarn consumers (then override `build_command`). |
| `build_command` | string  | `pnpm install --frozen-lockfile` + `pnpm build` | Multi-line bash. npm consumers override (e.g. `npm ci && npm run build`).                        |
| `artifact_path` | string  | `"dist"`                                        | Directory uploaded as the Pages artifact.                                                        |
| `env_json`      | string  | `"{}"`                                          | JSON object exported to the build via `$GITHUB_ENV` (e.g. `VITE_*`).                             |

No secrets — GitHub Pages auth is the built-in `GITHUB_TOKEN` via the `pages: write` + `id-token: write` permissions the caller grants. The `build` job fails fast if the build doesn't produce a non-empty `artifact_path`.

---

### `go-ci.yml`

CI for a Go service. The counterpart to `node-pnpm-ci.yml` and deliberately the same
shape: each step opts out by passing `""`, and the job is named `CI`, so a consumer
reports the check as `<caller job id> / CI`.

#### Caller example

```yaml
jobs:
  ci:
    uses: tinbee/ci-workflows/.github/workflows/go-ci.yml@v1
    with:
      buf: true
      sqlc_version: "1.31.1"
      generate_command: |
        buf generate
        sqlc generate
      generated_paths: internal/proto internal/cp/store/db
      lint_command: make lint
      golangci_version: v2.14
      post_command: make build-agent-linux
      # Only for a repo depending on a private module; see "Private modules" below.
      goprivate: "github.com/tinbee/*"
    secrets:
      private_module_ssh_key: ${{ secrets.FOLIOT_SDK_DEPLOY_KEY }}
```

#### Inputs

| Input               | Default               | Notes                                                                                                                                                                                                                         |
| ------------------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `go_version_file`   | `go.mod`              | Keeps CI and the module on one version.                                                                                                                                                                                       |
| `working_directory` | `.`                   | For a repo whose Go module is not at the root (a service mid-port).                                                                                                                                                           |
| `pre_command`       | `""`                  | Runs first, from the repo root. For starting a database the tests need — this workflow owns the job, so a caller cannot add `services:`.                                                                                      |
| `buf`               | `false`               | Install buf.                                                                                                                                                                                                                  |
| `sqlc_version`      | `""`                  | Empty skips it. **Pin it**: sqlc writes its version into generated output, so a floating version makes the freshness check fail for whoever is on a different one.                                                            |
| `generate_command`  | `""`                  | Regenerates committed code.                                                                                                                                                                                                   |
| `generated_paths`   | `""`                  | Paths the freshness check diffs afterwards.                                                                                                                                                                                   |
| `lint_command`      | `""`                  | Project lint beyond golangci-lint.                                                                                                                                                                                            |
| `golangci_version`  | `""`                  | Empty skips the action.                                                                                                                                                                                                       |
| `build_command`     | `go build ./...`      |                                                                                                                                                                                                                               |
| `test_command`      | `go test -race ./...` | Race detector on by default.                                                                                                                                                                                                  |
| `post_command`      | `""`                  | Runs last. Cross-compiles, artifact builds.                                                                                                                                                                                   |
| `govulncheck`       | `true`                | Vulnerabilities in _reachable_ code, not just the module graph.                                                                                                                                                               |
| `gofmt_check`       | `true`                | Fails when `gofmt -l` names a file.                                                                                                                                                                                           |
| `timeout_minutes`   | `20`                  |                                                                                                                                                                                                                               |
| `env_json`          | `{}`                  | Extra env for every step.                                                                                                                                                                                                     |
| `goprivate`         | `""`                  | Comma-separated module-path globs to fetch direct rather than through `proxy.golang.org`, e.g. `github.com/tinbee/*`. Required for any private module. Pair with the `private_module_ssh_key` secret — each is useless alone. |

#### Secrets

| Secret                   | Required | Notes                                                                                                                                                                                                                                                      |
| ------------------------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `private_module_ssh_key` | no       | Private half of a read-only **deploy key on the repo holding the private modules** (not on the caller). Loaded into an `ssh-agent` for the job, with an `insteadOf` rewrite so the HTTPS URL Go asks for is fetched over SSH. Omit it and the step no-ops. |

#### Private modules

A repo's own `GITHUB_TOKEN` cannot read another repo, and cannot read any repo in another
org — so a module shared between orgs needs its own credential. Two settings, and each is
useless alone:

```yaml
jobs:
  ci:
    uses: tinbee/ci-workflows/.github/workflows/go-ci.yml@v1
    with:
      goprivate: "github.com/tinbee/*"
    secrets:
      private_module_ssh_key: ${{ secrets.FOLIOT_SDK_DEPLOY_KEY }}
```

Setting **exactly one** of the two is an error rather than a warning, because
half-configured fails later and elsewhere: `goprivate` alone makes Go fetch direct from a
URL it cannot authenticate, a key alone leaves Go asking the public proxy for a module it
cannot see, and both read as "module not found" from whichever of `buf`, `sqlc`,
`golangci-lint` or `go build` happens to fetch first.

To set the credential up, on the repo that **holds** the modules:

```bash
KEYDIR=$(mktemp -d)
ssh-keygen -t ed25519 -N "" -C "<consumer> reads <owner>/<repo>" -f "$KEYDIR/key"
gh repo deploy-key add "$KEYDIR/key.pub" --repo <owner>/<repo> --title "<consumer> (read-only)"
gh secret set FOLIOT_SDK_DEPLOY_KEY --repo <consumer-owner>/<consumer-repo> < "$KEYDIR/key"
rm -rf "$KEYDIR"
```

No `--allow-write`, so a leaked key cannot push. **No passphrase** — CI cannot enter one,
and the resulting `error in libcrypto` names nothing.

Locally, developers need the same two halves: `go env -w GOPRIVATE='github.com/tinbee/*'`
and a matching `url.insteadOf` in `~/.gitconfig`. Both are in the dotfiles repo
(`scripts/go.sh` and `git/gitconfig`).

#### Migrating an inline CI job onto this

**It renames the check.** An inline job named `CI` reports `CI`; a job calling this
reports `<job id> / CI`. Update the required-status-check ruleset in the same change and
re-PUT it, or every check goes green and every PR stays blocked with nothing red to
explain it. A drift guard comparing the ruleset file against what the workflow reports
belongs in the caller — see instastack's `ci.yml`.

### `pr-scope-guard.yml`

Fails a PR that carries commits belonging to another **open** PR against the same base,
listing each shared SHA and its subject.

It exists because `tinbee/envmesh#116` was branched from an open PR's branch instead of
from `main`, so it carried six commits under a one-commit title. Merging it put four
review rounds' worth of still-under-review changes on `main` — a destructive migration and
a data-delivery regression among them. Nothing was bypassed: a real PR, green CI, every
required check satisfied. No gate looked at what the PR actually contained.

Deliberately narrow. A genuine stacked PR sets its base to the branch below it, so the
shared commits fall outside `base..head` and it never trips. For real overlap against the
base branch the escape label makes it a decision rather than an accident.

#### Caller example

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]
    branches: ["main"]

permissions:
  contents: read
  pull-requests: read

jobs:
  scope:
    uses: tinbee/ci-workflows/.github/workflows/pr-scope-guard.yml@v1
```

**The status-check context is `scope / pr-scope-guard`** — the caller's job id, then this
workflow's job name. Require that exact string in the ruleset. A required context that
never reports blocks every PR with no obvious cause, so if you name the caller job
something other than `scope`, the context changes with it.

#### Inputs

| Input          | Default      | Notes                                                                                                   |
| -------------- | ------------ | ------------------------------------------------------------------------------------------------------- |
| `base_branch`  | `main`       | The base PRs are checked against. Other open PRs against this same base are what a PR is compared with. |
| `escape_label` | `stacked-pr` | Label that makes overlap deliberate and skips the check.                                                |

### `claude-review.yml`

A cold-context model review of a pull request: only the diff, the repo and the rule docs
are visible to it, none of the author's reasoning. Requested by adding a label once the PR
has settled; the job consumes the label, so adding it again requests another pass.

Runs on a Max subscription token from `claude setup-token`, not an API key.

Findings post as **inline review comments — one thread per finding**, with anything that
has no line to anchor to (a stale PR description, a migration already on `main`) in the
review body. Threads are what make a finding individually answerable: reply with why you
disagree and resolve it, exactly as with Copilot. They are also what
`required_review_thread_resolution` counts, so a repo with that rule in its ruleset gets the
review as a real merge gate with a per-finding override — where a single PR comment carrying
N findings is invisible to it, and a PR can merge with every finding still open.

A green check means a review **exists**, not merely that the model ran: the job fails when
the model finishes without publishing anything, because the action itself reports success
either way, and a fifteen-minute review that never got posted is otherwise indistinguishable
from a clean one. It counts reviews, inline threads and issue comments, since the prompt has
three publish paths — the inline review, a body-only review when an anchor is rejected, and
a plain PR comment as the last fallback. A run that published zero threads is warned about
rather than failed: it means the gate silently went missing, and the Review step log says
whether that was a clean diff or a fallback.

#### Caller example

```yaml
on:
  pull_request:
    types: [labeled]

jobs:
  claude-review:
    uses: tinbee/ci-workflows/.github/workflows/claude-review.yml@v1
    with:
      ci_check_name: "ci / CI"
      project_context: "A workflow orchestrator. TypeScript, mid-port to Go."
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Pass the secret **explicitly**, as above, not with `secrets: inherit`. `inherit` forwards
organization secrets only when the called workflow is in the caller's organization, so it
works for tinbee repos and hands over nothing for a caller in any other org — the job
starts and fails in five seconds with `Secret CLAUDE_CODE_OAUTH_TOKEN is required, but not
provided while calling`, with the secret present and shared with the repo. The explicit
form is evaluated in the caller's context and works from every org, so it is the only form
documented here.

Two more things that only show up on a caller's first run:

- **The secret lives in the CALLER's org (or repo), never here.** A reusable workflow reads
  nothing from the org that hosts it; every expression in `secrets:` resolves against the
  calling repository. A new org adopting this workflow sets its own
  `CLAUDE_CODE_OAUTH_TOKEN` first.
- **Changes to the caller's `claude-review.yml` must land on the default branch before a
  review can run again.** `claude-code-action` refuses to run — exits green, posts nothing,
  logs `Workflow validation failed. The workflow file must exist and have identical content
to the version on the repository's default branch` — when the PR's copy of the workflow
  differs from `main`'s. So a fix to the caller file goes to `main` in its own PR, the
  feature branch is updated from `main`, and only then is the label re-added.

#### Inputs

| Input                | Default                       | Notes                                                                                                                                                                                                                                                                                                          |
| -------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci_check_name`      | `ci / CI`                     | **The input most likely to be wrong.** A repo whose CI _calls_ a reusable workflow reports `<job id> / <inner job name>`; a repo with an inline job named `CI` reports `CI`. Wrong value means every review is skipped. The step names the mismatch and lists the available names rather than just timing out. |
| `label`              | `claude-review`               | Consumed as the job's first step.                                                                                                                                                                                                                                                                              |
| `model_label_prefix` | `claude-review:`              | A label `<prefix><model>[:<effort>]` reviews that one PR with that model; `""` turns it off. See _Choosing a model_.                                                                                                                                                                                           |
| `project_context`    | `""`                          | One or two sentences on what the service is and what language. Without it the model infers the domain from the diff.                                                                                                                                                                                           |
| `project_rules`      | `docs/review-rules/README.md` | The caller's own invariants. Skipped when absent.                                                                                                                                                                                                                                                              |
| `rules_ref`          | `v1`                          | Ref of this repo the shared `review-rules/` come from.                                                                                                                                                                                                                                                         |
| `model`              | `claude-sonnet-5-5`           | Default model; a model label overrides it per PR. Sonnet 5.5, changed from `claude-opus-5` in v1.15.0.                                                                                                                                                                                                         |
| `effort`             | `high`                        | Default `--effort`: `low`, `medium`, `high`, `xhigh` or `max`; a model label can override it.                                                                                                                                                                                                                  |
| `max_turns`          | `200`                         | A runaway guard, not a budget: the action fails a run that finishes past the cap after the review is already posted and paid for.                                                                                                                                                                              |
| `ci_wait_attempts`   | `90`                          | 20s each, so 30 minutes.                                                                                                                                                                                                                                                                                       |

#### Choosing a model

`claude-review` reviews with the `model` and `effort` inputs. A label named
`claude-review:<model>[:<effort>]` reviews that one PR with that model instead:

| Label                               | Reviews with                     |
| ----------------------------------- | -------------------------------- |
| `claude-review`                     | the `model` / `effort` inputs    |
| `claude-review:opus`                | `--model opus`, default effort   |
| `claude-review:claude-opus-5-5:max` | `--model claude-opus-5-5`, `max` |
| `claude-review:sonnet:xhigh`        | `--model sonnet`, `xhigh`        |

The model goes to the CLI **as written**: an alias (`opus`, `sonnet`) or a full model id, with
the CLI's optional context suffix (`opus[1m]`). There is no mapping and no allow-list in the
workflow, so a model released tomorrow works as soon as the CLI accepts its id — create the
label and nothing else changes. Labels are per repository; create one with
`gh label create "claude-review:opus"`.

- A label that does not parse (`claude-review:`, an effort that is not one of the five) fails
  the job in seconds, before the CI wait, with the accepted forms in the error.
- A model the CLI does not know fails the Review step; it never falls back to the default,
  because that would answer a different question than the one the label asked. A model newer
  than the action's CLI still runs, but the CLI assumes a 200k-token window for it.
- The model is held to a strict shape (letters, digits, `.`, `_`, `-`, optional `[1m]`)
  because it reaches the CLI's arguments. Whoever can apply a label can choose the model, and
  so spend its quota; that is triage access, the same people who can request a review.
- Caller workflows need no change: `types: [labeled]` already fires for every label.

#### Secrets

| Secret                    | Notes                                                                                                                                                                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Required. From `claude setup-token`. Set once at the org level **of each calling org** — the workflow reads the caller's secrets, not this repo's — and passed explicitly (see the caller example; `secrets: inherit` does not cross organizations). |

#### The rules it reviews against

`review-rules/` in this repository — one copy of each general Tin Bee rule, checked out
beside the caller's code. Consumer repos keep only their own invariants. See
[`review-rules/README.md`](review-rules/README.md) for the index and what each covers.

### `copilot-review.yml`

Requests a Copilot code review **on demand, by label** — the same shape as
`claude-review.yml`. Add the `copilot-review` label; the job consumes it and asks
Copilot, so adding it again asks again. Drafts are skipped.

This exists because Copilot's automatic per-push review is what hits the account rate
limit: with `review_on_push: true` in a repo's ruleset it re-reviews on **every** push, so
a four-push pull request collects five reviews. `rulesets/protect-main.json` sets that to
`false`, and this workflow is how you ask for the extra looks you actually want.

```yaml
on:
  pull_request:
    types: [labeled]

jobs:
  copilot-review:
    uses: tinbee/ci-workflows/.github/workflows/copilot-review.yml@v1
```

| Input   | Default          | Notes                                                               |
| ------- | ---------------- | ------------------------------------------------------------------- |
| `label` | `copilot-review` | The label that requests a review. Consumed as the job's first step. |

No secret needed — `GITHUB_TOKEN` with `pull-requests: write` can request a reviewer.

Two things worth knowing if you ever call the API by hand. The reviewer login needs the
**`[bot]` suffix** — `copilot-pull-request-reviewer[bot]` — or the API answers
`422 Reviews may only be requested from collaborators`, which reads as "Copilot can't be
requested through the API at all". And nothing appears in `requested_reviewers`
afterwards, because Copilot consumes the request rather than queueing it like a human: a
new review arriving is the only confirmation.

## Rulesets

`rulesets/protect-main.json` is the canonical `protect-main` branch ruleset — required
checks, no force-push, no deletion, PR required, thread resolution required, and Copilot
review with `review_on_push: false`. One definition instead of one per repo.

Applying is **manual and deliberate**, because there is no way to automate it without a
long-lived credential: reading or writing the rulesets API needs repo **admin**, and
`administration` is not among the permission scopes a workflow may request, so
`GITHUB_TOKEN` cannot be granted it. Your own `gh` login already has the admin, so run it
yourself:

```bash
git clone https://github.com/tinbee/ci-workflows && cd ci-workflows

# See whether a repo has drifted. Exits 0 if it matches, 1 with a diff if not.
./rulesets/apply.sh --check tinbee/foliot

# Apply it. Creates the ruleset if the repo has none.
./rulesets/apply.sh tinbee/foliot
```

**Extra required checks go on the command line**, and are the only field a repo is
expected to differ on. Quote any name containing spaces:

```bash
./rulesets/apply.sh tinbee/envmesh 'scope / pr-scope-guard'
```

Syncing the repos currently covered:

```bash
./rulesets/apply.sh tinbee/foliot
./rulesets/apply.sh instastack/instastack
./rulesets/apply.sh tinbee/envmesh 'scope / pr-scope-guard'
```

Notes on what it does and does not assert. It resolves the ruleset **by name**, never a
hardcoded id, because the id differs per repo. It compares only the fields the canonical
file claims to own — `name`, `target`, `enforcement`, `conditions`, `rules`,
`bypass_actors` — with keys sorted, so an id, a timestamp or key ordering is never
reported as drift. An unreadable listing exits 2 with the API's own response rather than
claiming the ruleset is missing: those need opposite responses, and conflating them would
send you to the wrong place.

`required_review_thread_resolution` is `true` in the canonical file, and it is the rule
that actually stops a merge over open findings — both review bots submit as `COMMENTED`,
so `reviewDecision` stays clean however many threads are unresolved.

## Versioning

- Floating major tags: `@v1`, `@v2`, ... — consumers pin to these, pick up patch + minor changes automatically.
- Full versions: `@v1.0.0`, `@v1.0.1`, ... — for pinning to an exact release.
- Breaking changes always bump the floating major (`@v1` → `@v2`); consumers migrate on their own schedule.

## Adding a new workflow

1. Add `.github/workflows/<name>.yml` with `on: workflow_call:`.
2. Document inputs + secrets here.
3. Migrate one consumer as the proof.
4. Bump version (`v1.x.x` for new workflow under existing major; `v2.0.0` if changing existing workflow's input/secret contract).
