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
      role_to_assume:          ${{ secrets.AWS_CLOUDFRONT_ROLE_TO_ASSUME }}
      s3_bucket:               ${{ secrets.AWS_S3_BUCKET }}
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
      setup_pnpm: false                    # no package.json
      cache_control_overrides: ""          # disable multi-pass sync
      default_cache_control: ""            # no Cache-Control header
      invalidation_paths: "/*"             # invalidate everything
      sync_excludes: |
        .git/*
        .github/*
      content_type_fixups: |
        [{"ext":".ics","content_type":"text/calendar; charset=utf-8","cache_control":"public, max-age=3600"}]
    secrets: { ... }
```

#### Inputs

| Input | Type | Default | Notes |
|---|---|---|---|
| `node_version` | string | `"24"` | Passed to `actions/setup-node`. |
| `build_command` | string | `""` | Multi-line bash; skipped when empty. |
| `source_dir` | string | `"dist/"` | What to sync to S3. |
| `sync_excludes` | string | `""` | Newline-separated `--exclude` patterns (applies to every sync pass). |
| `cache_control_overrides` | string | `'[{"path_pattern":"assets/*","cache_control":"public, max-age=31536000, immutable"}]'` | JSON array of per-pattern Cache-Control overrides. Each entry runs as a separate `aws s3 sync` pass before the default. Pass `""` to disable multi-pass entirely. |
| `default_cache_control` | string | `"public, max-age=0, must-revalidate"` | Cache-Control for files NOT matched by any override. Pass `""` to omit the header (S3 default). |
| `content_type_fixups` | string | `""` | JSON array of per-extension Content-Type fixups. Each entry needs `ext`, `content_type`, optional `cache_control`. Runs after all sync passes. |
| `invalidation_paths` | string | `"/ /index.html"` | Space-separated CloudFront paths. SPA-friendly default. Pass `"/*"` for legacy static sites. |
| `env_json` | string | `"{}"` | JSON object exported to `$GITHUB_ENV` before the build step. Use for `VITE_*` / `NEXT_PUBLIC_*` build-time config. |
| `aws_region` | string | required | e.g. `us-east-1`. Pass via `vars.X` or hardcode — **NOT** `secrets.X` (the `with:` block forbids the secrets context). |
| `setup_pnpm` | boolean | `true` | Whether to set up pnpm + pnpm cache. Set to `false` for consumers without `package.json` or `packageManager` field. |

#### Secrets

| Secret | Notes |
|---|---|
| `role_to_assume` | IAM role ARN for OIDC. Role must trust `token.actions.githubusercontent.com` and the calling repo. |
| `s3_bucket` | Bucket name, no `s3://` prefix. |
| `cloudfront_distribution` | Distribution ID. |

#### Validation

All required inputs/secrets (`aws_region`, `role_to_assume`, `s3_bucket`, `cloudfront_distribution`) are checked **non-empty** as the first step, before any AWS call. `required: true` only guarantees the caller *passed* a value — not that it's non-empty — so a missing `vars.AWS_REGION` (which resolves to `""`) or an unset secret fails fast here with a `::error::` annotation naming exactly what's missing, instead of a cryptic failure mid-deploy. The reusable workflow is the source of correctness; a consumer that isn't configured correctly is told precisely what to fix.

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

| Input | Type | Default | Notes |
|---|---|---|---|
| `node_version_file` | string | `".nvmrc"` | Single source of truth shared with local dev. Pass `""` to use `node_version` literal instead. |
| `node_version` | string | `"24"` | Only used when `node_version_file` is empty. |
| `install_command` | string | `"pnpm install --frozen-lockfile"` | Empty to skip (rare). |
| `pre_check_command` | string | `""` | Codegen / schema generation. Runs after install, before format/lint/typecheck. |
| `format_check_command` | string | `"pnpm format:check"` | Empty to skip. |
| `lint_command` | string | `"pnpm lint"` | Empty to skip. |
| `typecheck_command` | string | `"pnpm -r typecheck"` | Empty to skip. |
| `build_command` | string | `"pnpm -r build"` | Empty to skip. |
| `test_command` | string | `"pnpm -r test"` | Empty to skip. |
| `env_json` | string | `"{}"` | JSON object of env vars exported to `$GITHUB_ENV`. |
| `timeout_minutes` | number | `15` | Job timeout. |

The job is always named `CI` — required-status-check rulesets should reference this name.

---

## Versioning

- Floating major tags: `@v1`, `@v2`, ... — consumers pin to these, pick up patch + minor changes automatically.
- Full versions: `@v1.0.0`, `@v1.0.1`, ... — for pinning to an exact release.
- Breaking changes always bump the floating major (`@v1` → `@v2`); consumers migrate on their own schedule.

## Adding a new workflow

1. Add `.github/workflows/<name>.yml` with `on: workflow_call:`.
2. Document inputs + secrets here.
3. Migrate one consumer as the proof.
4. Bump version (`v1.x.x` for new workflow under existing major; `v2.0.0` if changing existing workflow's input/secret contract).
