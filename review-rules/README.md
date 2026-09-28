# Review rules

The rules a reviewer — human or automated — holds every Tin Bee change to. **One copy,
here**, so a rule cannot drift between repositories: a rule that exists in six places is
five stale copies and one that happens to be right.

`claude-review.yml` checks this directory out beside the code under review. A consumer repo
keeps only its OWN invariants, in `docs/review-rules/README.md`; everything general lives
here.

These were distilled from real incidents across several services. Their code samples are
whatever language the failure happened in, and their "Source" sections cite files in the
repository where it happened — **not** the one being reviewed. The rule is what transfers,
not the sample: do not go looking for `packages/auth` in a project that has no such
directory.

## The index

Read this file, then read the rules that apply to the change in front of you. Reading all
eleven on a two-file diff wastes the budget that should go on the diff.

| Rule | Read it when the diff touches |
| --- | --- |
| [`db-migrations.md`](db-migrations.md) | Any migration, in any tool. Non-negotiable: the SQL body belongs in the PR description and every destructive operation is named. |
| [`toctou-mitigation.md`](toctou-mitigation.md) | A check feeding an async use — queues, cron, optimistic UI, distributed locks. Anywhere state can move between the two. |
| [`redis-cron-lock.md`](redis-cron-lock.md) | "One replica owns this scheduled job" coordination, or any lock whose work spans external I/O. |
| [`tenant-scope-from-token.md`](tenant-scope-from-token.md) | Any multi-tenant read or write. Counts and aggregates too — those are the ones people forget to scope. |
| [`default-deny-authz.md`](default-deny-authz.md) | A new route, or anything touching a global auth guard. The dangerous case is a *missing* decorator, not a wrong one. |
| [`no-secrets-in-urls.md`](no-secrets-in-urls.md) | Any endpoint taking a reason, token, secret or PII. Query strings land in access logs, CDN logs, `Referer` headers and APM traces. |
| [`kms-envelope-encryption.md`](kms-envelope-encryption.md) | Persisting anything secret to the customer that the service must read back. |
| [`outbound-call-timeout.md`](outbound-call-timeout.md) | Any outbound call, to a third party or a sibling service. A bare `fetch` with no timeout is a near-certain defect. |
| [`keyset-pagination-precision.md`](keyset-pagination-precision.md) | Any cursor-paginated list. In TypeScript plus Postgres a `Date`-derived cursor is lossy *by construction*, and the failure is silent omission. |
| [`rate-limiting-architecture.md`](rate-limiting-architecture.md) | An internet-facing surface, or a login / token-mint / reveal / deploy endpoint. |
| [`rest-adapter-design.md`](rest-adapter-design.md) | Code wrapping a third-party REST API or SDK. Skip it for a service that wraps nothing. |

## What earns a rule its place here

Each exists because something went wrong once **and the failure was silent** — it passed
tests, passed review, and surfaced later as missing data, a leaked secret or an outage.
That is the filter. A defect that announces itself does not need a rule; the stack trace
is the rule.

Style, naming and structure are deliberately absent. They are worth having, and they are
not worth a reviewer's attention when the same pass could be finding a cross-tenant read.

## Writing and changing rules

Fix a rule **here**, once. If a consumer repo has grown a local copy, delete the copy
rather than keeping both — the point of this directory is that there is nothing to
reconcile.

When a review in one repository turns up a defect the rules did not cover, add it here
rather than to that repository's own invariants, unless it genuinely cannot happen
anywhere else. A rule that lags the best file in the fleet is itself the bug: new repos
copy the rule, so the rule has to lead.

**Keep the prose formatter-proof.** Some consumer repos run Prettier over Markdown, and
that is what corrupted the copies this directory replaced. Three constructs to avoid,
each of which has already caused a real regression:

- **Bare globs in prose.** `*.sql` reads as emphasis and comes back as `_.sql`. Backtick
  every wildcard.
- **A line-leading `+` meaning "and".** It becomes a list bullet, orphaning the clause
  after it. Write "plus", or fold it into the previous line.
- **An inline code span straddling a line break.** The continuation gets dedented to
  column 0, breaking the enclosing list item. Keep the span on one line.
