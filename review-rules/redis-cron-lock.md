# Redis distributed cron lock

Canonical pattern for "single-replica owns this scheduled job"
coordination when the work spans external I/O (DNS lookups, HTTP
calls, NATS publishes, etc.). Reach for this by reflex on any new
cron in a multi-replica service. **Do NOT use Postgres advisory
locks** for this case — they leak under pooled connections OR force
holding an interactive DB transaction across external I/O.

## The pattern

```ts
import { randomUUID } from "node:crypto";

const LOCK_KEY = "service:cron:<cron-name>:lock";
const LOCK_TTL_SECONDS = 600; // > worst-case sweep duration

const RELEASE_SCRIPT = `
if redis.call('get', KEYS[1]) == ARGV[1] then
  return redis.call('del', KEYS[1])
else
  return 0
end
`;

class SomeCron {
  private lockToken: string | null = null;

  // Cast RedisService → ioredis surface (canonical wrapper pattern).
  private get redis(): Redis {
    return this.redisService as unknown as Redis;
  }

  async sweepOnce(): Promise<void> {
    const acquired = await this.tryAcquireLock();
    if (!acquired) {
      this.logger.debug("Another replica holds the lock; skipping");
      return;
    }
    try {
      await this.runSweep();
    } finally {
      await this.releaseLock();
    }
  }

  private async tryAcquireLock(): Promise<boolean> {
    const token = randomUUID();
    const result = await this.redis.set(
      LOCK_KEY,
      token,
      "EX",
      LOCK_TTL_SECONDS,
      "NX"
    );
    if (result === "OK") {
      this.lockToken = token;
      return true;
    }
    return false;
  }

  private async releaseLock(): Promise<void> {
    const token = this.lockToken;
    this.lockToken = null;
    if (!token) return;
    try {
      // Atomic compare-and-del at Redis. Only DELs the key when our
      // token still owns it — defends against the "TTL expired,
      // another replica took over, our finally-block deletes theirs"
      // race.
      await this.redis.eval(RELEASE_SCRIPT, 1, LOCK_KEY, token);
    } catch (err) {
      // TTL will release the lock anyway. Don't escalate.
      this.logger.warn({ err }, "Lock release failed (TTL fallback)");
    }
  }
}
```

## Why this exact shape

Three alternatives that I tried and rejected:

1. **`pg_try_advisory_lock` (session-scoped)** — leaks under Prisma's
   pool. Acquire and unlock can land on different backend
   connections; lock stuck indefinitely → all future sweeps skip.
2. **`pg_try_advisory_xact_lock` inside `$transaction`** — fixes the
   leak but holds an interactive Postgres transaction across DNS /
   NATS / external HTTP calls. Idle-in-transaction blocks VACUUM and
   eats pool capacity.
3. **Redis `SET NX EX` with blind `DEL` release** — auto-recovery
   via TTL, no DB transaction across I/O. **But** if a sweep runs
   longer than TTL, another replica acquires the key after expiry,
   then the original's `finally` block DELs the **other** replica's
   lock (classic distributed-lock race).
4. **Redis `SET NX EX` with per-acquisition UUID token + Lua
   compare-and-del** ← **this pattern.** Only DELs the key when our
   token still owns it; if TTL expired and another replica took
   over, the script returns 0 and we leave their lock intact.

## Choosing the TTL

`LOCK_TTL_SECONDS` MUST exceed the worst-case sweep duration so a
crashed replica doesn't auto-release while another replica is still
running. 10 min covers a 10k-row fleet × external-call latency. The
non-crash path explicit-DELs the key on exit, so steady-state hold
is bounded by actual sweep time, not TTL.

## Spec pattern

```ts
function makeRedisMock() {
  return {
    set: jest.fn().mockResolvedValue("OK"),
    eval: jest.fn().mockResolvedValue(1),
  };
}

it("skips entirely when another replica holds the lock", async () => {
  redis.set.mockResolvedValueOnce(null);
  await cron.sweepOnce();
  expect(workMock).not.toHaveBeenCalled();
  expect(redis.eval).not.toHaveBeenCalled(); // no release if no acquire
});

it("acquires with a per-run token and releases via compare-and-del", async () => {
  await cron.sweepOnce();
  const setArgs = redis.set.mock.calls[0];
  expect(setArgs[1]).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-/i); // UUID token
  expect(setArgs.slice(2)).toEqual(["EX", 600, "NX"]);
  const evalArgs = redis.eval.mock.calls[0];
  expect(evalArgs[3]).toBe(setArgs[1]); // same token round-trips
});
```

## Per-cron lock keys

Each cron MUST get its own `LOCK_KEY`. Sharing keys across crons
would serialize them artificially and add cross-cron contention.
Format: `<service>:cron:<distinct-name>:lock`.
