# REST adapter design principles

When wrapping a REST/SDK API and reconciling user-supplied state
(records, resources, configuration), three correctness gaps cost
review rounds repeatedly. Always check for them before declaring an
adapter done.

## 1. Implement pagination from day one

Even when typical response sizes seem small, a list endpoint that
returns "first N" without following the `next_page` /
`result_info.total_pages` / `IsTruncated` field is a
data-corruption time bomb. The failure mode is silent truncation —
verify reports false missing/mismatch, apply overwrites the wrong
slot. **Customers always bring fleets larger than your test
fixtures.**

Provider-specific shapes:

- **Cloudflare:** `result_info.{page, per_page, total_pages}`
  envelope. Loop until `page >= total_pages`.
- **Route53:** `IsTruncated` flag + `NextRecordName` + `NextRecordType`
  cursor. Stop when `!IsTruncated` OR when returned name no longer
  matches your filter (records are sorted).
- **GitHub:** `Link` header with `rel="next"`. Use the `gh` CLI's
  built-in pagination or follow the link header manually.
- **Stripe:** `has_more: boolean` + `starting_after: <id>` cursor.

```ts
// Canonical Cloudflare paginate shape
async listRecords(token, zoneId, filter): Promise<Record[]> {
  const out: Record[] = [];
  let page = 1;
  for (;;) {
    const params = new URLSearchParams({ ...filter, per_page: "100", page: String(page) });
    const res = await this.cfRequestWithMeta<Record[]>(token, "GET", `/zones/${zoneId}/dns_records?${params}`);
    const result = res.result ?? [];
    out.push(...result);
    const info = res.result_info;
    if (!info || page >= info.total_pages || result.length === 0) return out;
    page += 1;
  }
}
```

## 2. JSON-array inputs are plural along multiple dimensions

If the adapter is handed an array of records (`expectedRecords`,
`subscription_lines`, `webhook_targets`), it varies along multiple
KEY DIMENSIONS, e.g. (host, type, value, ttl) for DNS records.
**The adapter MUST handle every combination; you cannot assume "one
host's worth" or "one value per (host, type)."**

Concrete failures caught in real reviews:

- **Multi-VALUE per key:** N expected at the same (host, type)
  collapses to overwriting a single record N times → N-1 values
  silently lost.
- **Multi-HOST per binding:** `verify()` lists records only for
  `binding.hostname` but `expectedRecords` includes apex + verification
  TXT at a different subdomain → records at the other host always
  reported missing.

**Discipline before writing the happy path:** explicitly enumerate
"what dimensions does this array vary along?" Then write at least
one "multi-X" test per dimension before declaring it done.
Single-record happy paths catch zero of these.

```ts
// Pattern: group by every key dimension, list once per group, reconcile per-value
const grouped = new Map<string, Record[]>();
for (const r of expected) {
  const key = `${r.host.toLowerCase()}\t${r.type}`;
  (grouped.get(key) ?? grouped.set(key, []).get(key)!).push(r);
}
for (const group of grouped.values()) {
  const existing = await listFor(group[0].host, group[0].type);
  // Match each expected to an existing slot — exact-content match,
  // else reuse stale slot, else create.
  for (const exp of group) {
    const exact = existing.findIndex((r) => r.content === exp.value);
    if (exact >= 0) {
      existing.splice(exact, 1);
      continue;
    } // no-op or PUT only on TTL change
    const stale = existing.shift();
    if (stale) await update(stale.id, exp);
    else await create(exp);
  }
}
```

## 3. Validate at YOUR boundary, not the upstream's

When the upstream API rejects something invalid (Route53 rejects a
ChangeBatch with conflicting TTLs at the same Name+Type; Stripe
rejects amounts in non-integer cents; AWS rejects fractional
durations), let the wrapper surface the issue with a CLEAR
domain-specific error BEFORE sending the request.

Upstream errors are usually opaque (`InvalidChangeBatch`,
`parameter_invalid`); your boundary error can name the offending
field and value. Common pre-flight validations:

- **Numeric range:** `Number.isSafeInteger(ttl) && ttl > 0`, NOT
  just `Number.isFinite` (lets fractional values through).
- **Enum membership:** validate against the actual enum values you
  declared, not just `string`.
- **Cross-record consistency:** if the upstream requires a single
  shared value across a record set (e.g. TTL for a Route53 record
  set), assert it before sending and throw with
  `(host, type): [conflicting values]`.
- **Required fields:** check stored credentials shape (`accessKeyId`,
  `secretAccessKey`) before constructing a client; throw with which
  field is missing.

Cost of these guards is ~5 lines each; cost of letting upstream
reject is a confused user + an opaque support ticket.

## Lifecycle disciplines

- **String-literal enum values, not Prisma enum imports** (when
  using Prisma): `readonly strategy: DnsStrategy = "ROUTE53"` rather
  than `DnsStrategy.ROUTE53`. Importing the enum as a runtime value
  loads the generated client and trips ts-jest on `import.meta.url`.
- **Defensive parse for JSON columns:** when reading a `Json` column
  into a typed shape, narrow each field with `typeof` checks AND
  carry through optional fields. Silently dropping `ttl` because the
  parser doesn't see it is the same class of bug as #1 — a field is
  present in the input, but the adapter forgets it exists.
- **`transient` vs hard failure in verify-style checks:** when the
  upstream is unreachable (timeout, DNS resolver error, 5xx),
  return a `transient` discriminant — caller does NOT escalate
  status. Reserve `missing` / `mismatch` for cases where the
  upstream gave a clear "this isn't here" or "this is wrong" answer.

## Spec patterns

- At least one **multi-X** test per varying dimension: multi-host,
  multi-value, multi-page.
- TTL/optional-field carry-through: pass a non-default value, assert
  it round-trips into the upstream call.
- Error-priority test: when verify can produce both `missing` and
  `mismatch` (or `transient` and either), assert the priority order
  matches the documented contract.
- Resource-leak test for adapters using `globalThis.fetch` or other
  module-level state: save + restore in `beforeEach` / `afterEach`
  so spec ordering across Jest workers can't matter.
