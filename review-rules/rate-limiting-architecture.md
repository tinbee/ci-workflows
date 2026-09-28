# Rate-limiting architecture

How to place and back a rate limiter in a multi-replica service. The
per-counter mechanics (atomic INCR+EXPIRE, never INCR-then-EXPIRE) live
in the global CLAUDE.md "Redis counter with TTL window" rule and
[`redis-cron-lock.md`](redis-cron-lock.md); THIS rule is about the three
architectural decisions that surround the counter: *where* the limiter
runs, *what backs it*, and *how it fails*.

Learned across instastack (custom Redis 2-tier gateway limiter),
envmesh (`@nestjs/throttler` + Redis storage), and glasscycle
(Postgres-backed limiter).

## 1. Run the limiter BEFORE auth

Mount the global per-IP limiter *ahead* of the auth guard/middleware, so
brute-force and credential-stuffing on the unauthenticated path is
throttled before it ever reaches token verification (which is itself
expensive — JWKS, Argon2, DB lookups). A limiter that only runs after
auth cannot protect the login/mint/verify endpoints that need it most.

- NestJS: register `ThrottlerGuard` as `APP_GUARD` (runs before route
  guards), or mount limiter middleware before the auth middleware.
- Gateway/proxy services: if routes are claimed by proxy `pathFilter`
  and never reach a Nest controller, `ThrottlerGuard` can't fire — use
  limiter *middleware* mounted before the proxy + before bearer verify
  (instastack gateway).

**Two-tier** is the strong form: a coarse global per-IP limit *before*
auth (e.g. 300/60s) + a finer per-principal limit *after* auth (e.g.
20/60s), with a **separate counter per route** so one expensive route
can't drain another's budget.

## 2. Back it with a replica-safe store

In-memory throttler state is per-replica and effectively disabled behind
>1 task. Pick a shared store:

| Store | When | Notes |
|---|---|---|
| `@nestjs/throttler` + `@nest-lab/throttler-storage-redis` | Default, Redis already present | Simplest. Build the storage's **own** IORedis from config — the DI factory runs before `RedisService.onModuleInit`, so reading the shared client there is `undefined`. |
| Custom Redis + Lua | Need accurate `Retry-After`, per-route counters, or proxy-path limiting | `INCR` then `EXPIRE` only when `current == 1`; register via `defineCommand`. |
| Postgres model (`rateLimit` table, upsert-on-fresh-window) | No Redis in the stack | Durable across replicas without a Redis dep (glasscycle). |

`@nestjs/throttler` v6 `ttl` is **milliseconds** — use the exported
`seconds(60)` helper so the unit is unambiguous (reviewers misflag the
raw ms repeatedly).

## 3. Fail OPEN on store error

A Redis/DB blip in the limiter must NOT 500 the request. Catch the store
error, log it, and allow the request through. (Contrast: the store can
still be a hard *boot* dependency — reject at `onModuleInit` if
unreachable — but at request time, degrade to "unlimited" rather than
"down".) The limiter protects against abuse; it must not become a new
single point of failure on the hot path.

```ts
try {
  const { allowed, retryAfter } = await consume(key, limit, windowMs);
  if (!allowed) { res.setHeader("Retry-After", retryAfter); throw new ThrottledException(); }
} catch (err) {
  if (err instanceof ThrottledException) throw err;
  this.logger.warn({ err }, "rate-limit store error — failing open");
  // fall through: allow the request
}
```

## Supporting disciplines

- **Key off the REAL client IP.** This depends on `trust proxy` being
  correct for your topology: a service directly internet-exposed sets
  `trust proxy: false` (socket peer = client; blocks `X-Forwarded-For`
  spoofing of the rate-limit key); behind exactly one proxy (ALB/
  Railway) set `trust proxy: 1`. Getting this wrong either collapses all
  clients into one bucket or lets clients spoof their bucket.
- **Tight per-route caps** on expensive/abuse-prone endpoints: login,
  token mint, secret reveal, deploy trigger, webhook (`@Throttle`).
- **Hash tokens in counter keys** — `sha256(token)[:16]`, never the raw
  token; bump only the triggering counter on the throttled path to bound
  key cardinality.
- **Pre-flight throttle before the expensive verify.** For a token-mint
  / login path, check the limit BEFORE the Argon2/bcrypt verify, so a
  flood can't amplify into CPU exhaustion. Return an identical error for
  throttled / invalid / not-found so probes can't distinguish.
- **Telemetry on the auth path is fire-and-forget** — `void
  recordFailure(...)`; never `await` the store inside `verify()`.
- **Infra defense-in-depth:** for public surfaces, an AWS WAFv2
  rate-based rule in front of CloudFront/ALB throttles L7 floods before
  they reach the app. App-layer limiting stays; WAF is additive.

## Traps

1. **Limiter after auth** — leaves the unauth brute-force path open.
2. **In-memory store behind >1 replica** — silently per-replica, so the
   effective limit is N× the configured value.
3. **Fail-closed limiter** — a Redis hiccup 500s every request; the
   limiter becomes the outage.
4. **INCR then separate EXPIRE** — a crash between leaks the key with no
   TTL forever (see the global Redis-counter rule).
5. **`ttl` unit confusion** in throttler v6 (ms, not s).
6. **Wrong `trust proxy`** — bucket collapse or spoofable keys.

## Lint heuristic

PR review: (1) is the global limiter mounted before auth? (2) is its
store replica-safe? (3) does the request path fail open on store error?
(4) are login/mint/reveal endpoints individually capped? Any "no" is a
finding.

## Source

Distilled from instastack gateway 2-tier Redis limiter + mint throttle,
envmesh throttler+Redis-storage config, and glasscycle Postgres limiter,
2026-05-23. Promoted because every internet-facing service needs a
limiter and the three architectural choices (placement, store, failure
mode) are independent of which library backs it.
