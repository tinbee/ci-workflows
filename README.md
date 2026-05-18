# ci-workflows

Reusable GitHub Actions workflows for `tinbee` + `mkurtay` repos. Single source of truth for action versions and CI/CD step shapes — bump an action here once, every consumer picks it up on their next run.

Public so any org's repo can consume it. Reusable workflows in private repos can only be called from the same org; making this public is the standard pattern for cross-org sharing.

## Available workflows

### `deploy-s3-cloudfront.yml`

Deploy a static site to AWS S3 + CloudFront, with optional pre-deploy build step, S3 sync excludes, per-extension Content-Type fixups, and CloudFront invalidation.

**Caller example** (see `mkurtay/cal/.github/workflows/deploy.yml` for the live reference):

```yaml
name: Deploy to S3 + CloudFront
on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  deploy:
    uses: tinbee/ci-workflows/.github/workflows/deploy-s3-cloudfront.yml@v1
    with:
      aws_region: us-east-1
      build_command: |
        pnpm install --frozen-lockfile
        pnpm build
      source_dir: dist/
      sync_excludes: |
        .git/*
        .github/*
      content_type_fixups: |
        [{"ext":".ics","content_type":"text/calendar; charset=utf-8","cache_control":"public, max-age=3600"}]
      invalidation_paths: "/*"
    secrets:
      role_to_assume:          ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
      s3_bucket:               ${{ secrets.AWS_S3_BUCKET }}
      cloudfront_distribution: ${{ secrets.AWS_CLOUDFRONT_DISTRIBUTION_ID }}
```

**Inputs**

| Input | Type | Default | Notes |
|---|---|---|---|
| `node_version` | string | `"24"` | Passed to `actions/setup-node`. |
| `build_command` | string | `""` | Multi-line bash; skipped when empty. |
| `source_dir` | string | `"dist/"` | What to sync to S3. |
| `sync_excludes` | string | `""` | Newline-separated `--exclude` patterns. |
| `content_type_fixups` | string | `""` | JSON array; each entry needs `ext`, `content_type`, optional `cache_control`. |
| `invalidation_paths` | string | `"/*"` | Space-separated CloudFront paths. |
| `aws_region` | string | required | e.g. `us-east-1`. |

**Secrets**

| Secret | Notes |
|---|---|
| `role_to_assume` | IAM role ARN for OIDC. Role must trust `token.actions.githubusercontent.com` and the calling repo. |
| `s3_bucket` | Bucket name, no `s3://` prefix. |
| `cloudfront_distribution` | Distribution ID. |

## Versioning

- Floating major tags: `@v1`, `@v2`, ... — consumers pin to these, pick up patch + minor changes automatically.
- Full versions: `@v1.0.0`, `@v1.0.1`, ... — for pinning to an exact release.
- Breaking changes always bump the floating major (`@v1` → `@v2`); consumers migrate on their own schedule.

## Adding a new workflow

1. Add `.github/workflows/<name>.yml` with `on: workflow_call:`.
2. Document inputs + secrets here.
3. Migrate one consumer as the proof.
4. Bump version (`v1.x.x` for new workflow under existing major; `v2.0.0` if changing existing workflow's input/secret contract).
