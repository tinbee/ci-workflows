# Never pass critical info through URL parameters

When designing any endpoint that accepts a piece of information you
would not want logged outside the audit log — a user-typed reason, a
PII field, a secret, a session token, a webhook payload — that input
MUST travel in the **request body**, never as a query string param,
never in the URL path.

Query strings and URL paths are routinely captured outside the audit
log in places you don't control:

- **Web server access logs** (nginx, Apache, IIS) log full URLs by
  default, including query strings.
- **Reverse-proxy / CDN logs** (Cloudflare, Fastly, ALB, ELB) capture
  every URL. Cloudflare retains them for analytics.
- **Browser history** records the full URL of every navigation. Search
  bars autocomplete against it.
- **Referer headers** leak the URL to every cross-origin resource the
  page loads next.
- **APM / observability tooling** (Datadog APM, Sentry, New Relic,
  OpenTelemetry HTTP spans) records full URLs as part of trace data
  by default.
- **Browser dev tools** + screenshots / screen recordings show the
  URL bar in plain text.
- **Bookmarks and shared links** capture the URL verbatim.

If you put a piece of sensitive info into a URL, the audit log gets
ONE copy and every layer above gets free copies forever. The whole
purpose of having a tightly-controlled audit log is defeated.

## Concrete signals you have this problem

- An endpoint accepts a `?reason=`, `?note=`, `?why=`, `?ticket=`,
  `?token=`, `?password=` query param.
- A "secret" is in a URL path segment (e.g.
  `/v1/secrets/<secret-value>/verify`).
- A webhook signature is being verified against URL params (it
  should be in headers or body).
- A reset-password / unsubscribe / share link puts the token in the
  URL path or query, and the link is sent over email (which often
  proxies through link-tracking services that log the URL).

## The fix

Whatever-the-input-was moves to the request body. The endpoint switches
from GET to POST (or stays POST/PUT/PATCH if it already was). The
audit row carries the field; nothing else does.

```ts
// BAD — reason leaks to nginx logs, Cloudflare logs, browser history,
//       Datadog APM, every Referer header on the next page
@Get("values")
read(
  @Query("reveal") reveal: string,
  @Query("reason") reason: string,
  ...
) { ... }

// GOOD — reason confined to the request body + the audit row
class RevealValuesDto {
  @IsString() @MinLength(8) @MaxLength(500)
  reason!: string;
  ...
}

@Post("values/reveal")
@HttpCode(200)
reveal(@Body() dto: RevealValuesDto, ...) {
  // audit.record({ reason: dto.reason, ... })
}
```

## Exceptions (legitimate URL-param use)

Stable, non-sensitive identifiers and filters belong in URL params:

- **Resource IDs** (`/v1/projects/:project_id`) — purpose IS to
  identify the URL.
- **Pagination cursors** (`?cursor=opaque-string`) — not sensitive;
  intentionally cacheable/bookmarkable.
- **Filters that don't carry user secrets** (`?status=pending`,
  `?env=production`) — same.
- **`?key=ENV_VAR_NAME` to scope a request to a specific definition**
  — key NAMES are non-sensitive (the whole point of putting them in
  schema docs). Key VALUES are sensitive and must never be in URLs.

The distinguishing test: would you be uncomfortable if this value
appeared verbatim in a screenshot of your nginx access log shared
with someone outside your audit-log-readers? If yes, body. If no,
URL is fine.

## Cross-functional reminder

This rule applies to every project — frontend (browser → server),
backend (service → service), and infrastructure (CI → API). When
designing a new endpoint, the question "where does this input go?"
should always be considered BEFORE writing the route signature.

## Source

Distilled from envmesh PR #10 review round 2 (2026-05-18), where the
initial reveal-flow design put a user-typed reason in
`?reason=<text>`. Copilot caught it; the fix was a new POST endpoint
with the reason in the body. Generalized here because the same
mistake will be tempting on any future "audit-this-action" endpoint
across any project — secrets in URLs is one of those defaults that
*almost* always works until the day it doesn't.
