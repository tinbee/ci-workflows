# Keyset pagination: the cursor must carry full precision

A cursor-paginated list endpoint keyed on a timestamp **silently drops rows**
whenever the cursor's timestamp is less precise than the column's. Not an error,
not a duplicate — just rows that no page ever returns.

In a TypeScript + Postgres project this is the **default** state of affairs, not
an edge case:

- Postgres `TIMESTAMPTZ` / `TIMESTAMP` store **microseconds** (6 digits).
- JavaScript `Date` holds **milliseconds** (3 digits) and cannot represent more.

So **any cursor built from a `Date`-typed value, or from a string derived from
one, is lossy by construction.** `toISOString()` truncates. `getTime()`
truncates. Prisma and Drizzle both hand you a `Date` for a timestamp column, so
both inherit it. This is not a driver bug to work around; it is a type mismatch
that has to be handled deliberately.

## Why it loses rows, concretely

Keyset ("seek") pagination ends each page by naming the last row, and asks the
next page for everything strictly past it:

```sql
SELECT * FROM runs
WHERE (created_at, id) < ($cursorAt, $cursorId)   -- row comparison, id is the tiebreak
ORDER BY created_at DESC, id DESC
LIMIT $n
```

Seven rows, as Postgres actually stored them, with `limit 3`:

```
16:34:59.941760   ─┐
16:34:59.941383    ├ page 1
16:34:59.940995   ─┘  ← cursor built from this row
16:34:59.940636       ← SKIPPED
16:34:59.940252       ← SKIPPED
16:34:59.939867   ─┐ page 2
16:34:59.939081   ─┘
```

`.940995` truncated to milliseconds is `.940000`. Page 2 therefore asks for
`created_at < .940000`, and `.940636` and `.940252` are both **greater** than
that, so they fail the predicate. They are returned by no page at all. The client
sees 5 of 7 and has no way to know.

**The error is one-directional.** Truncation only ever moves the boundary
*earlier*, so the effect is only ever exclusion. A repeat would be noticed at
once; a silent omission reads as "there were fewer records than I thought". That
asymmetry is the whole reason this survives in production.

It needs two rows inside one millisecond to fire, which is completely ordinary:
any batch insert, import, or `for` loop of writes produces it.

## The fixes, in order of preference

### 1. Paginate on a monotonic key instead of a timestamp

If the ordering does not have to be chronological, key on the primary key or a
dedicated sequence. `BIGSERIAL` is exact, monotonic, and has no precision to
lose, so the entire problem class disappears.

```sql
WHERE id < $cursorId ORDER BY id DESC LIMIT $n
```

Prisma's own `cursor: { id }` does this. Prefer it whenever "newest first" can be
satisfied by "highest id first" — for append-only tables it usually can.

### 2. Make the stored precision match the language's

If rows genuinely need timestamp ordering, declare the column at millisecond
precision so there is nothing to truncate:

```sql
created_at TIMESTAMPTZ(3) NOT NULL DEFAULT now()
```

`Date` is then lossless for that column and a cursor built from it is exact.
Cheap and permanent on a new schema. On an existing table this is an
`ALTER COLUMN … TYPE`, which is destructive (it rounds stored values), so treat
it as a real migration — see [`db-migrations.md`](db-migrations.md).

**Check what your ORM actually emits — the defaults differ, and that difference
alone decides whether a project has this bug:**

| declaration | emitted column | cursor from a `Date` |
| --- | --- | --- |
| Prisma `DateTime` (no attribute) | `TIMESTAMP(3)` | **safe** — matches `Date` exactly |
| Prisma `DateTime @db.Timestamptz` | `timestamptz` (µs) | **hazardous** |
| Prisma `DateTime @db.Timestamptz(3)` | `timestamptz(3)` | safe |
| Drizzle `timestamp(...)` / `timestamp(..., { withTimezone: true })` | `timestamp` / `timestamptz` (µs) | **hazardous** |
| Drizzle `timestamp(..., { precision: 3 })` | `timestamp(3)` | safe |
| hand-written `TIMESTAMPTZ` | µs | **hazardous** |

So Prisma is safe *by default* and becomes unsafe the moment someone adds
`@db.Timestamptz` for timezone correctness — a change that looks purely like an
improvement and silently breaks every keyset paginator on that table. Drizzle is
the reverse: hazardous by default, because it never adds a precision unless you
ask. Audited 18 projects on 2026-09-28 and this table was the entire difference
between "five paginators, all fine" and "latent".

Verify against the migration SQL, not the schema file — grep the emitted
declarations and confirm every paginated column carries an explicit precision:

```bash
grep -rhoiE 'TIMESTAMP(TZ)?(\([0-9]\))?' --include='*.sql' path/to/migrations \
  | sort | uniq -c | sort -rn
```

Read the result carefully: `CURRENT_TIMESTAMP` (a default expression) and a
column *named* `timestamp` both match that pattern and are not column types.

### 3. Carry the timestamp at full precision, as text

When the column must keep microseconds, fetch a **second, full-precision
rendering** for the cursor only, and never build the cursor from the value the
driver coerced:

```ts
const res = await db.query<Row & { cursor_at: string }>(
  `SELECT r.*,
          to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS cursor_at
     FROM runs r
    WHERE ${where.join(" AND ")}
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT $${params.length}`,
  params,
);
const last = rows.at(-1);
const nextCursor = hasMore && last ? encodeCursor(last.cursor_at, last.id) : null;
```

Two details that matter:

- **Cast, don't coerce.** The point of `to_char` is that the value arrives as
  `text` (OID 25) rather than `timestamptz` (OID 1184), so a driver-level type
  parser cannot touch it. A bare `::text` also works but follows the session's
  `DateStyle`; `to_char` pins the format.
- **Do not "fix" the type parser instead.** Relaxing a global timestamp parser to
  preserve microseconds changes *every* timestamp the API emits — a wire contract
  change for the sake of one internal value.

Send the string straight back as a query parameter; Postgres parses it as
`timestamptz` in the comparison, so it round-trips losslessly. Old cursors keep
decoding, because a millisecond-precision string still parses — they simply
self-correct from the next page onward, so no cursor migration is needed.

## Keep the two representations as separate types

The root cause is one value serving two purposes with different requirements:

| purpose | requirement |
| --- | --- |
| **display** (API responses) | stable, predictable, usually lossy on purpose |
| **comparison** (cursors, dedupe keys, watermarks) | exact |

When a single variable serves both, the lossy form wins silently. Make them
distinct types or distinct named constants, so the difference is visible at every
use site. In Go, two formats rather than one:

```go
const isoMillis  = "2006-01-02T15:04:05.000Z"      // wire: fixed 3 digits
const cursorTime = "2006-01-02T15:04:05.000000Z"   // cursor: full precision
```

(Go has the mirror-image *display* hazard: `time.Time`'s default JSON marshalling
**trims** trailing zeros, so the same instant renders as `.345Z`, `.34Z` or
`.3Z` depending on the value. Pin the width for anything a client or a
byte-comparison test reads.)

## Test discipline: force the collision

A test that inserts rows in a loop and pages through them is **a coin flip**, and
it lands on the wrong side under the slower driver:

- `pgx` (Go) lands inserts ~380 µs apart → several per millisecond → catches it
  nearly every run.
- `node-postgres` lands them ~1 ms apart → usually one per millisecond → passes
  while the bug is fully present.

So set the timestamps explicitly rather than trusting insert timing:

```ts
for (const [i, id] of created.entries()) {
  await pool.query(
    `UPDATE runs SET created_at = timestamptz '2026-01-01 00:00:00.500000+00'
       + ($2::int || ' microseconds')::interval WHERE id = $1`,
    [id, i * 100],
  );
}
```

Then page with a limit smaller than the group and assert the **set** of ids seen
equals the set created. Assert no id appears twice as well — but remember the
failing direction is omission, so a duplicate check alone proves nothing.

## Other cursor hazards worth checking at the same time

- **No tiebreak.** Ordering by a timestamp alone with `<` skips rows sharing a
  timestamp; with `<=` it repeats them. Always a composite with a unique column:
  `(created_at, id)`.
- **Mutable sort key.** A cursor on `updated_at` is not stable — a row can move
  and be visited twice or never. Paginate on something immutable.
- **`OFFSET` under concurrent writes.** Not a precision bug, same symptom:
  inserts shift the window and rows slide across page boundaries. Keyset avoids
  it, which is usually why it was chosen.
- **Walking a set to act on it** (bulk jobs) should key on the primary key, not
  the timestamp, so a row cannot shift between pages while the job runs.
- **Floats as cursors** (scores, ranks) have the same lossy-representation
  problem via JSON number round-tripping. Prefer an exact type plus an id
  tiebreak.

## Lint heuristic

In review of any paginated list endpoint:

1. What is the cursor built from? If a `Date`, a `Date`-derived string, or
   anything the driver coerced from a timestamp — **flag it**.
2. Is the sort key a composite ending in a unique, immutable column?
3. Does a test force multiple rows into one clock tick, or does it rely on insert
   timing?

```bash
# Cursors encoded from a timestamp field are the shape to look at
grep -rn "encodeCursor\|nextCursor\|cursor =" src --include="*.ts" \
  | grep -iE "created_?at|updated_?at|timestamp|\.at\b"
```

## Source

Foliot, 2026-09-28. Found while porting the run store from TypeScript to Go:
`GET /runs` had silently skipped runs since the endpoint was written, because
`db/pool.ts` routes every `timestamptz` through `new Date(v).toISOString()` for
predictable response serialisation, and the cursor was built from that projected
value. Confirmed at **4 of 7 runs returned** with the page boundary inside one
millisecond. The Go port hit it on its first test run purely because pgx inserts
faster than node-postgres — the TypeScript suite had been spacing inserts ~1 ms
apart and passing for the bug's entire life.

Generalised because several TypeScript + Postgres services here have
cursor-paginated list endpoints, and in that combination the lossy cursor is the
default outcome rather than a mistake someone has to make.
