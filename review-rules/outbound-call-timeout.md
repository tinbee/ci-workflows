# Outbound call timeout discipline

Every outbound call from a service — whether to a third-party
provider (GitHub, AWS, Cloudflare, Stripe, ...) or to another
internal service — needs a per-request timeout. Without one, a
stalled upstream (slow DNS, network partition, server hang)
keeps the request hanging indefinitely and ties up request
workers in the caller. At low traffic this is invisible; at
production load it cascades into 503s.

This rule was learned on instastack PR #33: I shipped a `fetch`
call to users-service without `AbortController`. Copilot caught
it. Generalized here because every other external integration
will eventually hit the same trap.

## The pattern

### Native `fetch`

```ts
const REQUEST_TIMEOUT_MS = 5_000;

const controller = new AbortController();
const timeout = setTimeout(
  () => controller.abort(),
  REQUEST_TIMEOUT_MS,
);

let response: Response;
try {
  response = await fetch(url, {
    method: "POST",
    headers: { ... },
    body: ...,
    signal: controller.signal,
  });
} catch (err) {
  // Distinguish abort (timeout) from other network errors so
  // logs + thrown messages are accurate. Both surface as
  // transient ServiceUnavailableException — caller decides
  // retry vs fail.
  const aborted = controller.signal.aborted;
  this.logger.warn(
    { err, url, aborted },
    aborted
      ? "permission check timed out"
      : "permission check network error",
  );
  throw new ServiceUnavailableException(
    aborted
      ? "users-service timed out"
      : "users-service unavailable",
  );
} finally {
  clearTimeout(timeout);
}
```

The `finally` block is non-negotiable — without it, successful
fetches leak their timer until it fires (no harm, but accumulates
in long-running processes).

### SDK calls (configure the SDK's timeout option)

For SDKs that wrap their own HTTP, use the SDK's configurable
timeout — don't try to wrap the SDK in your own AbortController.
The SDK already has internal cancellation primitives that won't
play nicely with an external signal.

**AWS SDK v3** via `@smithy/node-http-handler`:

```ts
import { NodeHttpHandler } from "@smithy/node-http-handler";

new SomeAwsClient({
  requestHandler: new NodeHttpHandler({
    connectionTimeout: 5_000,
    requestTimeout: 5_000,
  }),
});
```

**Octokit** (GitHub SDK):

```ts
new Octokit({
  request: { timeout: 5_000 },
});
```

**`@nestjs/axios`** / raw `axios`:

```ts
this.http.request({
  url,
  method,
  timeout: 5_000,
  ...
});
```

## Default values

- **5 seconds for `fetch`** — synchronous in-request paths
  (e.g., authz check, internal API call). Tighter than SDK
  defaults because these are internal hops.
- **10 seconds for SDKs** — third-party providers may legitimately
  take longer (Cloudflare 15s for some operations, AWS
  pagination), but a single call shouldn't exceed 10s in the
  happy path.

These are starting points. Override per-(service, endpoint) when
the upstream's documented p99 demands it.

## When to retry

Timeout retry policy depends on the call's lifecycle:

- **Synchronous in-request (Pattern A):** 0-3 retries on
  `5xx` + abort/timeout + network error. Total budget ~3-5s
  including retries. NOT retryable: `4xx` (caller bug) or
  user cancel.
- **Long-running saga steps (Pattern B):** in-process retries plus
  JetStream/queue redelivery on 429 / throttle. The job
  must NOT fail on transient throttle — slow it down via
  redelivery instead.
- **Background jobs (Pattern C):** retry with exponential
  backoff capped at the queue's max-deliveries setting.
  Emit a "needs human attention" event when cap hits.

These three patterns were worked out in full for one service's
external-call primitive; the rule above is the universal piece, and
the choice of pattern follows from the call's lifecycle rather than
from anything that service did.

## Common traps

1. **`finally` missing.** Successful path leaves a timer
   pending until it fires. Process-level OK but indicates the
   author didn't think through cleanup.
2. **Treating `AbortError` as a hard failure.** It IS a
   failure, but a TRANSIENT one. Surface as
   `ServiceUnavailableException` (or your framework's
   transient-error type), not as `InternalServerError`.
3. **Conflating timeout and 4xx.** A `4xx` (caller bug) and a
   timeout (upstream stall) are different transient classes.
   4xx should NOT be retried; timeout SHOULD. Distinguish them
   in the catch block.
4. **`AbortController` re-used across retries.** Each retry
   needs its own controller and timer. Re-using means the
   first abort permanently disables subsequent attempts.
5. **Forwarding caller-supplied `AbortSignal` AND adding a
   timeout signal.** SDKs that take a `signal` already chain
   to caller-cancel; use one or the other, not both. Or use
   `AbortSignal.any([callerSignal, timeoutSignal])` if you
   really need both.

## Lint heuristic

PR review check: search the diff for `await fetch(` and any new
SDK client construction. Each one should either pass `signal:`
or configure a timeout on the SDK. Bare `await fetch(url)` is a
near-certain mistake.

## Source

Distilled from Copilot review round 1 on instastack PR #33
(2026-04-29). The bare `fetch` call without timeout was caught
in `services/deployments/src/authz/users-service.client.ts`;
generalized here to apply to every outbound call across every
service.
