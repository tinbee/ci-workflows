# Database migration discipline

Universal rules for any project that uses a migration tool (Prisma,
Drizzle, Knex, TypeORM, Alembic, ActiveRecord, golang-migrate, raw
SQL files — same hazards regardless of the orchestrator). The rules
exist because **`migrate deploy` is just a SQL replayer** — the
destructive operation is already in the migration file by the time
CI runs it. The only place to *prevent* data loss is migration
authoring and review, not deploy. The remaining layers (backups,
expand/contract, CI gating) are *recovery* and *delay tactics*, not
prevention.

## Rule 1: every migration PR includes the SQL body in the description

**No exceptions.** Every PR that adds or modifies a migration file
(`prisma/migrations/<ts>/migration.sql`, `drizzle/<ts>.sql`,
`db/migrate/*.rb`, `migrations/*.sql`, etc.) must paste the migration
body verbatim in the PR description and explicitly call out any
operation from the destructive-op list below.

This rule exists because:

- Reviewers default to trusting that "the ORM generated it correctly."
  ORMs generate *syntactically correct* SQL, not *intent-correct* SQL.
  A column rename in `schema.prisma` produces
  `DROP COLUMN x; ADD COLUMN y;` — both correct SQL, both silent data
  loss.
- Diffs hide the SQL behind a filename like
  `20260518_120000_rename_thing/migration.sql`. The PR author saw the
  diff one time; subsequent readers need it in the description.
- The act of pasting the SQL forces the author to read what they're
  asking to apply. Most destructive-migration incidents are caught
  in this re-reading, not in review.

**PR description template:**

````markdown
## Migration

This PR adds `apps/api/prisma/migrations/20260518_120000_thing/migration.sql`.

### SQL

```sql
-- paste full migration body here
```

### Destructive operations

- [ ] None
- [ ] DROP COLUMN — explain which data + why safe to lose
- [ ] DROP TABLE — same
- [ ] ALTER COLUMN ... TYPE — explain whether precision/truncation
- [ ] ALTER COLUMN ... SET NOT NULL — explain backfill of existing rows
- [ ] TRUNCATE / DELETE — same
- [ ] Column rename generated as DROP+ADD — replaced with `RENAME`?
````

If any destructive box is checked, the PR description must also
state which **expand/contract phase** this is (see Rule 3).

## Rule 2: destructive-operation list (the regex)

These are the operations that destroy data, in order of frequency.
A CI step can scan migration files for them; humans should know them
by heart.

| Operation | Why destructive | Safe alternative |
| --- | --- | --- |
| `DROP TABLE` | All rows gone | Phase 1: stop reading. Phase 2 (later release): drop. |
| `DROP COLUMN` | All values in that column gone | Same expand/contract. |
| `TRUNCATE` | All rows gone (cheaper than DELETE, no WHERE possible) | Almost never appropriate in a migration. |
| `DELETE FROM <t>` *(no WHERE)* | All rows gone | Same. |
| `ALTER COLUMN ... TYPE <smaller>` | Truncation or coercion-failure | Two-phase: add new col → backfill → swap → drop. |
| `ALTER COLUMN ... SET NOT NULL` | Existing NULL rows fail the migration | Backfill NULLs first in an earlier migration. |
| `ALTER COLUMN ... DROP DEFAULT` *(usually)* | New inserts may now fail at the app layer | Coordinate with code change. |
| Column rename via `DROP + ADD` | All values in old column gone | Use `ALTER TABLE ... RENAME COLUMN`. |

**Safe-by-default (the regex MUST NOT flag these):**

- `DROP INDEX` — only affects query plans, not data
- `DROP CONSTRAINT` — relaxes validation; doesn't lose data
- `ALTER COLUMN ... DROP NOT NULL` — opposite direction: allows MORE
  values; existing data still satisfies
- `CREATE TABLE`, `ADD COLUMN`, `CREATE INDEX`, etc. — purely additive

**Canonical detection regex** (case-insensitive, multiline):

```bash
grep -E -i \
  '(^|[[:space:]])(DROP[[:space:]]+TABLE|DROP[[:space:]]+COLUMN|TRUNCATE|ALTER[[:space:]]+COLUMN[[:space:]]+[^[:space:]]+[[:space:]]+TYPE|ALTER[[:space:]]+COLUMN[[:space:]]+[^[:space:]]+[[:space:]]+SET[[:space:]]+NOT[[:space:]]+NULL|DELETE[[:space:]]+FROM[[:space:]]+[^[:space:]]+[[:space:]]*;)' \
  migration.sql
```

Tune for false positives as needed (e.g. `DELETE FROM` followed by a
`WHERE` clause may be intentional). The regex's job is to be loud and
slightly over-eager; the human's job is to silence false positives
in PR review, not to tighten the regex.

## Rule 3: expand/contract — never bundle destructive change with the code that depends on it

The single most important habit. The pattern:

```
Release N      (expand):   add new column, dual-write, code keeps reading old
Release N+1    (verify):   code reads new column. Watch for a release cycle.
Release N+2    (contract): drop old column. Code change: nothing — the
                           column is already unused.
```

Why: if release N goes wrong and you roll back, you roll back **code
only** — schema is still safe because nothing destructive shipped yet.
If you bundle the drop into release N and roll back code, the old code
references a column that doesn't exist → outage.

This is universal. Renames, type changes, table splits — all expand/
contract:

- **Rename column:** add new + dual-write → backfill → switch reads →
  drop old (4 releases minimum).
- **Split column into two:** add new cols + dual-write → backfill →
  switch reads → drop old col.
- **Change FK target:** add new FK col → backfill → switch reads/writes
  → drop old FK col.

Single-release schema changes are fine for **purely additive** changes
(new tables, new nullable columns, new indexes). Anything subtractive
or coercive needs at least two releases.

## Rule 4: CI gates — destructive detection + conditional snapshot

The deploy workflow has two parallel responsibilities:

1. **Block obvious mistakes** — destructive migrations need an
   explicit "this is intentional" signal (manual approval in a GHA
   environment, or a PR-body marker).
2. **Take an additional safety net when the risk warrants it** —
   snapshot RDS *only* when the migration is destructive. Skip the
   snapshot cost (storage + time) for the 95% case of additive
   migrations.

### Conditional snapshot pattern (GitHub Actions)

```yaml
- name: Detect destructive migrations
  id: detect
  run: |
    set -euo pipefail
    DESTRUCTIVE=false
    # Determine the migration files new in this deploy.
    # For workflows triggered on push-to-main, compare HEAD against
    # the previous deploy SHA. Two ways to capture "previous deploy":
    #   (a) compare against HEAD~1 — works if every push-to-main is
    #       deployed and each deploy is one merge commit
    #   (b) keep a `last-deployed` tag and compare against it
    # (a) is simpler; (b) is correct if some commits are skipped.
    NEW_FILES=$(git diff --name-only HEAD~1..HEAD -- \
      'apps/api/prisma/migrations/**/migration.sql' || true)
    for f in $NEW_FILES; do
      if grep -E -i \
        '(^|[[:space:]])(DROP[[:space:]]+TABLE|DROP[[:space:]]+COLUMN|TRUNCATE|ALTER[[:space:]]+COLUMN[[:space:]]+[^[:space:]]+[[:space:]]+TYPE|ALTER[[:space:]]+COLUMN[[:space:]]+[^[:space:]]+[[:space:]]+SET[[:space:]]+NOT[[:space:]]+NULL)' \
        "$f"; then
        echo "::warning::Destructive migration detected in $f"
        DESTRUCTIVE=true
      fi
    done
    echo "destructive=$DESTRUCTIVE" >> "$GITHUB_OUTPUT"

- name: Pre-migration RDS snapshot (destructive only)
  if: steps.detect.outputs.destructive == 'true'
  run: |
    set -euo pipefail
    SNAPSHOT_ID="pre-mig-${GITHUB_SHA:0:7}-$(date +%s)"
    aws rds create-db-snapshot \
      --db-instance-identifier <prod-instance-id> \
      --db-snapshot-identifier "$SNAPSHOT_ID" \
      --region us-east-1
    aws rds wait db-snapshot-available \
      --db-snapshot-identifier "$SNAPSHOT_ID" \
      --region us-east-1
    echo "Snapshot $SNAPSHOT_ID complete"

# Optional gate: require manual approval before applying destructive
# migrations. Wire via a GHA environment with required reviewers.
- name: Apply migrations
  environment: ${{ steps.detect.outputs.destructive == 'true' && 'production-destructive' || 'production' }}
  run: |
    # invoke migration step here — for ECS: aws ecs run-task on a
    # migration task definition that runs `prisma migrate deploy`
    # (NO command override needed — same image, no shell-encoded URLs)
```

The `environment: production-destructive` line gates destructive
migrations on a GHA environment that requires a reviewer click,
while non-destructive migrations proceed against a `production`
environment with no manual gate. Configure both environments in
the repo's Settings → Environments.

### False-positive escape hatch

When a migration is *intentionally* destructive (e.g. dropping a
column you've been expand/contracting for two releases), the
regex still flags it. The fix is not to weaken the regex; it's to
let the human approve via the GHA environment click. The friction
*is* the point: every destructive deploy gets one explicit human
ack.

If a project frequently has intentional destructives, add a PR-body
marker the CI can recognize:

```
migration-allow-destructive: dropping users.legacy_field after
 expand/contract phases 1-3 shipped in releases 1.4, 1.5, 1.6
```

CI step grep's the PR body for `migration-allow-destructive:` and
skips the manual gate (but STILL takes the snapshot — that's free
insurance regardless).

## Rule 4b: standard tooling — husky guard + PR call-out (default since 2026-08-23)

Two mechanisms make Rules 1–2 automatic instead of remembered; wire both
in every repo with a migration tool:

1. **Husky pre-commit migration guard** — blocks any commit that stages
   the schema file without also staging a migration, printing the exact
   generate command. Do NOT auto-generate in the hook: the point is that
   the author READS the generated SQL before staging it. Reference:
   `paperowl/.husky/pre-commit` (drizzle: `schema.ts` vs `drizzle/*.sql`),
   `biscuitcouch/.husky/pre-commit` (prisma: `schema.prisma` vs
   `prisma/migrations/*/migration.sql`).

2. **`db-migration-callout` reusable workflow**
   (`tinbee/ci-workflows/.github/workflows/db-migration-callout.yml@v1`,
   added v1.8.0) — on pull_request, posts a sticky PR comment with the
   full SQL of every changed migration file, a destructive-op scan
   (canonical regex from Rule 2, `ON DELETE` excluded), an
   expand/contract checklist when anything matches, and a `db-migration`
   label. Caller shape:
   ```yaml
   db-migration-callout:
     if: github.event_name == 'pull_request'
     uses: tinbee/ci-workflows/.github/workflows/db-migration-callout.yml@v1
     with:
       migration_globs: apps/api/prisma/migrations/**/migration.sql
   ```

## Rule 5: RDS backups + PITR are the floor, not the ceiling

Conditional snapshots are *additional precision*. They MUST sit on
top of:

- `backup_retention_period >= 7` (RDS automated backups; configure
  in your Terraform module)
- PITR-eligible engine (Postgres, MySQL, MariaDB — all default eligible)

The snapshot taken by the workflow has a few advantages over PITR:

- Named, durable beyond `backup_retention_period`
- Can be restored to a *new* instance for inspection without touching prod
- Tied to the deploy SHA in the snapshot identifier — easy to find
  "the snapshot from the deploy that broke things"

But automated backups are the universal safety net. If the snapshot
step fails (rare; AWS API hiccup), you should NOT be afraid to
continue — automated backups still have you covered for 7+ days.

## ORM-specific notes

### Prisma

- `prisma migrate dev` generates the SQL. Always inspect the
  generated `migration.sql` before committing. **Renames produce
  DROP+ADD** — hand-edit to use `ALTER TABLE ... RENAME COLUMN`.
- `prisma migrate deploy` is the prod-safe command. It only applies
  files in `migrations/`. It NEVER resets, NEVER prompts, NEVER
  generates new migrations.
- `prisma migrate reset` requires
  `PRISMA_USER_CONSENT_FOR_DANGEROUS_AI_ACTION` env var set to the
  exact consent text in Prisma 7+. Should never appear in any prod
  workflow.
- Driver-adapter mode (Prisma 7) reads `DATABASE_URL` from your code
  config (`prisma.config.ts`). Compose-from-parts logic for managed
  passwords (URL-encoding, sslmode flags) lives there — DO NOT
  re-implement in shell overrides.

### Drizzle

- **Versioned migrations are the DEFAULT from day one** (decided
  2026-08-23, paperowl): `drizzle-kit generate` + `drizzle-kit migrate`
  in the deploy path, never `push`. New repos wire this before the
  first prod deploy.
- `drizzle-kit generate` writes SQL files to `drizzle/`. Same
  review discipline applies.
- `drizzle-kit push` is for development only — applies schema
  directly without a migration file. **Never run in prod.** Two
  failure modes: destructive diffs apply unreviewed, and on
  ambiguous changes (rename, new unique constraint on populated
  column) it prompts interactively → dies in non-TTY deploy
  containers.
- **Baselining a DB that was already push-created:**
  `drizzle-kit migrate` tracks applied migrations in
  `drizzle.__drizzle_migrations` (id SERIAL, hash text, created_at
  bigint = the journal entry's `when`). To adopt migrations on an
  existing DB, insert a row for migration 0000 (hash = sha256 of the
  .sql file, created_at = `when` from `drizzle/meta/_journal.json`)
  instead of re-running it. Reference implementation — an idempotent
  deploy script that baselines only when "schema exists AND tracking
  table empty", then runs `drizzle-kit migrate`:
  `paperowl/apps/api/scripts/db-deploy.mjs`. Fresh DBs skip the
  baseline branch and apply 0000 normally, so the same script serves
  every environment.
- Prisma equivalent of the baseline:
  `prisma migrate resolve --applied <migration-name>`.

### Knex

- `knex migrate:make` scaffolds an up/down JS file. Review both
  directions — a wrong `down` makes rollback worse than no rollback.

### Raw SQL files (golang-migrate, dbmate, etc.)

- Same review discipline. Both `up.sql` and `down.sql` files in
  the PR description.

## Lint heuristic

When reviewing any PR that touches a directory named `migrations/`
or contains files matching `*.sql` under a versioned directory:

1. Open the SQL file. Read it.
2. Grep it for the destructive list above.
3. If anything matches, the PR body MUST explain it and MUST identify
   which expand/contract phase it represents.
4. If the workflow does NOT have a destructive-detection step yet,
   add one in this PR or in an immediate follow-up.

## Source

Distilled from envmesh Phase 7 first-deploy (2026-05-18). The
specific catalyst was setting up a prod-grade migration step in
`deploy-api.yml` after hours of debugging shell-override gymnastics
for one-off ECS migration tasks. The PR-description discipline
captures the lesson that "the ORM generated it" is not a substitute
for reading the SQL; the conditional-snapshot pattern captures the
"pay extra precision when risk warrants it" idea.

Universal because every long-lived project ends up with a migration
tool, and the failure modes are identical regardless of which tool.
