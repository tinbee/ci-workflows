# TOCTOU (Time-Of-Check-to-Time-Of-Use) mitigation

A CHECK at time A and a USE at time B are separated by a window
during which the underlying state can change. If the USE trusts
the CHECK's result instead of re-validating at use-time, an
attacker (or just normal concurrent activity) can flip the state
between A and B — the CHECK said green, the USE encounters red,
and the system runs with stale information.

This rule is the canonical handling pattern. It's universal:
filesystem races, async-queue handoffs, distributed locks, token
caching, optimistic-UI gaps. Once you have the lens, you spot
TOCTOU windows everywhere two operations on the same state are
separated by time someone else could write.

## The mitigation pattern

**Re-check at use-time. Don't trust the check-time result across
async boundaries.**

Concretely:
1. Pass **inputs** through the async boundary, not check-results.
2. Re-fetch + re-validate at the start of the USE phase.
3. Make the USE phase's check authoritative — the CHECK is a
   preview, not a gate.

```ts
// BAD — trust the check result across an async boundary
async function previewAndQueue(input) {
  const result = await check(input);   // time A
  if (!result.ok) return showError();
  await queue.send({ input, validatedAt: A });
  // ... time passes; queue worker picks up message at time B ...
  // queue worker trusts `validatedAt` and skips re-check → TOCTOU window
}

// GOOD — pass inputs only, re-check at use-time
async function previewAndQueue(input) {
  const preview = await check(input);   // for the user's preview
  if (!preview.ok) return showError();
  await queue.send({ input });          // pass INPUTS, not the check result
}
// queue worker:
async function process(msg) {
  const fresh = await check(msg.input); // re-check at USE time
  if (!fresh.ok) throw new PreflightFailedError(fresh.detail);
  // ... actual work ...
}
```

## When TOCTOU windows appear

- **Async queues** (NATS, SQS, BullMQ): producer checks → worker
  picks up message N seconds-to-minutes later → upstream state
  may have flipped.
- **JWT / token claims**: bake authz state into a token → grant
  is revoked server-side → token is still presented and "passes."
  See [`tenant-scope-from-token.md`](tenant-scope-from-token.md): authz lookups
  must be per-request, never token-cached.
- **Distributed locks**: acquire lock → do work → release lock.
  If release uses raw DELETE instead of compare-and-swap on a
  per-acquisition token, a TTL-expired-then-reacquired lock gets
  deleted by the original holder. Acquire with
  `SET key <uuid> NX EX <ttl-seconds>`, and release with a Lua script
  that DELs the key only when the stored value still equals this
  acquisition's uuid. See [`redis-cron-lock.md`](redis-cron-lock.md) for the
  full Lua CAS pattern.
- **Filesystem `access()` → `open()`**: classic textbook TOCTOU.
  Inode swaps via symlink races. Use `openat()` + descriptors,
  not paths re-resolved between calls.
- **Database read-modify-write** without `SELECT FOR UPDATE` or
  optimistic-concurrency-version columns: row read at T1, changed
  by another tx at T1.5, blindly overwritten at T2.
- **Optimistic UI dispatch**: click handler checks "can I do this?"
  client-side → fires server request → server doesn't re-check
  because the request "looks valid."

## The litmus test

When you see two operations on the same external state separated
by ANYTHING that takes time — a network call, a queue, a UI
event, a setTimeout, a worker message — ask:

1. **What can change between operation 1 and operation 2?**
2. **Does operation 2 trust operation 1's snapshot, or re-fetch?**

If 2 trusts 1, you have a TOCTOU window. Whether it matters depends
on how bad the bad outcome is and how likely the state change is.

## Common traps

1. **Caching the check result "for performance."** Once you're
   trusting the cache, you have a TOCTOU window equal to the TTL.
   Acceptable for low-stakes UI affordances; not for security
   gates.
2. **"The window is so small it can't happen."** Production
   timescales are not your testing timescales. Async queues
   stretch nanosecond gaps into seconds. Concurrent admins
   stretch seconds into "a single click took 30 seconds."
3. **Re-checking the check result instead of the actual state.**
   If you stored `{ valid: true, validatedAt: T }` and re-check
   `validatedAt < now`, you're checking a snapshot of a snapshot.
   Re-fetch the underlying state.
4. **Fix at the wrong layer.** Adding a UI confirmation dialog
   doesn't close a TOCTOU window in the backend. The fix lives
   wherever the USE phase is.

## When TOCTOU is acceptable

Not every TOCTOU window must be closed. The question is the
blast radius of being wrong:

- **Preview UIs** that explicitly say "checked just now" with a
  refresh button — the check is informational, the gate lives
  elsewhere.
- **Idempotent operations** where re-running with stale data
  produces the same correct result.
- **Operations protected by a downstream constraint** that fails
  fast (e.g., DB unique constraint, FK constraint) so the
  inconsistency surfaces cleanly even if the check-time prediction
  was wrong.

The discipline: if the USE phase has a clean failure mode AND the
window is bounded, you can leave the gap and let downstream catch
it. If the USE phase produces partial state on failure, you must
re-check.

## Source

instastack PR #125 (Phase 5.6, 2026-05-15). Wizard's Review-step
combined preflight (5.5) showed DNS rows green based on a picked
Cloudflare Connection. The deploy went through a NATS queue → the
executor's preflight didn't re-check the strategy + connection
state → a token revoked between click and execute would slip past
preflight and crash mid-saga at `applyDnsStep`. The fix moved the
DNS row evaluation into the executor's preflight, sourced from
the PERSISTED `DomainBinding` + a fresh Connection read, so
revocation surfaces at deployment "(preflight)" with the same
diagnostic the wizard would have shown.

Generalized here because the user uses multi-service async-
boundary architectures pervasively (NATS, JetStream, cron jobs)
and the same window opens any time a check feeds a queue.
