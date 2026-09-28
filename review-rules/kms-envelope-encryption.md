# KMS envelope encryption for secrets at rest

Canonical pattern for storing user/customer secret bytes (env var
values, API keys, tokens, connection strings) in a database when the
app must be able to read them back. Reach for this any time a service
persists a value that is *secret to the customer* and the service has
to decrypt it later (delivery, reveal, injection). Do NOT store secret
bytes as plaintext columns, and do NOT encrypt with a single static
app-level key — envelope encryption with a per-value data key wrapped
by KMS is the floor.

Learned building envmesh (`apps/api/src/crypto/kms.service.ts`) and
instastack deployments (`kms-envelope.service.ts`) — paths in those
services, not in whichever repo you are reviewing. Both store
customer secrets; both converged on this exact shape.

A third reference implementation, in Go, is Instastack's control plane
`internal/crypto/envelope.go`: per-value DEK, owner-binding AAD, and a
`Wrapper` interface behind which the local master key sits today and KMS
is the intended production wrapper. Same shape, different language — the
rule is not TypeScript-specific.

## The pattern

AES-256-GCM with a **per-value data key** that is itself encrypted
("wrapped") by a KMS CMK. The DB stores only the ciphertext + the
*wrapped* data key + IV + auth tag — never a plaintext key.

```ts
interface SealedValue {
  ciphertext: Buffer;   // AES-256-GCM output
  iv: Buffer;           // random 96-bit nonce, per seal
  authTag: Buffer;      // GCM auth tag
  encryptedDek: Buffer; // the data key, wrapped by KMS
  kmsKeyArn: string;    // which CMK wrapped it (for rotation/audit)
}

async function seal(plaintext: Buffer): Promise<SealedValue> {
  // 1. Ask KMS for a fresh data key: returns both plaintext + wrapped form.
  const { Plaintext: dek, CiphertextBlob: encryptedDek } =
    await kms.generateDataKey({ KeyId, KeySpec: "AES_256", EncryptionContext });
  try {
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", dek, iv);
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    return { ciphertext, iv, authTag: cipher.getAuthTag(), encryptedDek, kmsKeyArn };
  } finally {
    dek.fill(0); // 2. WIPE the plaintext data key immediately — non-negotiable.
  }
}
```

### Five rules that make it correct

1. **Wipe the plaintext DEK in `finally`.** The plaintext data key
   exists in process memory only for the duration of the encrypt/
   decrypt. `dek.fill(0)` in `finally` so it's zeroed even on throw.
   Same on the read side after `createDecipheriv`.

2. **Per-value IV, random, 96-bit.** Never reuse an IV with the same
   key (GCM nonce-reuse is catastrophic). A fresh `randomBytes(12)`
   per `seal` is free insurance.

3. **Encryption-context binding (owner binding).** Pass an
   `EncryptionContext` (e.g. `{ tenantId, definitionId }`) to both
   `generateDataKey` and `decrypt`. KMS makes the context part of the
   AAD, so a ciphertext + wrapped DEK row copied into another tenant's
   record **fails to decrypt**. This turns a DB-level cross-tenant row
   swap into a hard crypto failure instead of a data leak.

4. **TTL'd DEK cache with wipe-on-evict.** Decrypting the wrapped DEK
   via KMS on every read is slow + costs per-request. Cache the
   *unwrapped* DEK in memory keyed by `sha256(encryptedDek)`, **TTL ≤
   5 min, hard cap (e.g. 1024 entries)**, and wipe the buffer on
   eviction:
   ```ts
   new LRUCache<string, Buffer>({
     max: 1024,
     ttl: 5 * 60_000,
     dispose: (buf) => buf.fill(0), // zero the key when evicted
   });
   ```
   Clear the whole cache in `onModuleDestroy`. The TTL bounds how long
   a compromised process holds usable keys; the cap bounds memory.

5. **Selective encryption.** Only envelope-encrypt values flagged
   secret (`isSecret = true`); store non-secrets (`NODE_ENV`, `PORT`,
   `LOG_LEVEL`) as plaintext. Auto-classify on import by name, let the
   user override. This keeps KMS cost near-zero (envmesh: ~$1.22/mo)
   and keeps non-secret reads free.

## Enforce the plaintext-XOR-envelope invariant in the DB

A row is *either* a plaintext value *or* a full envelope — never both,
never neither. Encode it as a CHECK constraint so no code path can
write a half-sealed row. Prisma can't express CHECK, so hand-write it
in the migration:

```sql
ALTER TABLE "EnvVarValue" ADD CONSTRAINT "value_plaintext_xor_envelope"
CHECK (
  ("plaintext" IS NOT NULL AND "ciphertext" IS NULL AND "encryptedDek" IS NULL)
  OR
  ("plaintext" IS NULL AND "ciphertext" IS NOT NULL AND "encryptedDek" IS NOT NULL
   AND "iv" IS NOT NULL AND "authTag" IS NOT NULL)
);
```

Apply to the history/audit table too. (See [`db-migrations.md`](db-migrations.md)
for the migration-PR discipline; a hand-written CHECK still pastes its
SQL in the PR body. For large tables split
`ADD CONSTRAINT ... NOT VALID` plus `VALIDATE` into two migration files
— Prisma wraps one file in one tx so a single-file pair gives no lock
benefit.)

## Audit as a precondition of disclosure

When a "reveal" path decrypts a secret for a human, the audit write is
not fire-and-forget — it **gates the disclosure**. Decrypt, then write
the audit row, and if the audit write fails, **throw and return
nothing**:

```ts
const revealed = await this.decryptAll(rows); // plaintext now in memory
try {
  await this.audit.record({ actor, action: "values.reveal", reason, keys });
} catch (err) {
  throw new InternalServerErrorException("Refused to reveal: audit write failed");
}
return revealed; // only reached if the disclosure is recorded
```

The reveal `reason` travels in the request **body**, never a URL param
([`no-secrets-in-urls.md`](no-secrets-in-urls.md)). Record the client IP in its
own audit column. The reveal endpoint is a POST-as-RPC: `@HttpCode(200)`
plus a tight per-route rate limit (`@Throttle`, e.g. 10/min/IP).

## Other disciplines

- **String-literal CMK config**, never `import { KMS }` as a runtime
  value in a file pulled into a Jest spec.
- **SDK timeout on the KMS client** — `@smithy/node-http-handler`
  `NodeHttpHandler({ connectionTimeout: 5000, requestTimeout: 10000 })`
  ([`outbound-call-timeout.md`](outbound-call-timeout.md)).
- **Mandatory log redaction** — the logger's redact list must include
  `value`, `plaintext`, `ciphertext`, `dek`, `password`, `secret`,
  `apiKey`, `privateKey`, `accessKey`, `authorization`, `cookie`. A new
  logger without this list is a review block.
- **Expose pure `sealWithDek` / `openWithDek`** (DEK passed in) for
  synchronous unit testing without a live KMS.
- **Rotation:** store `kmsKeyArn` per row so a CMK rotation can
  re-wrap lazily on next write; `enable_key_rotation = true` on the CMK.

## Lint heuristic

In review of any service that persists customer secrets:
1. Grep the schema for a plaintext column holding a secret-class value
   with no sibling `ciphertext`/`encryptedDek` → flag.
2. Grep `generateDataKey` / `createCipheriv` usage for a missing
   `.fill(0)` in `finally` → flag.
3. Confirm the DEK cache has a TTL + cap + `dispose` wipe (an
   unbounded plaintext-key cache is the anti-pattern).
4. Confirm a reveal path writes audit BEFORE returning plaintext.

## Source

Distilled from envmesh `crypto/kms.service.ts` + the value XOR-check
migration, and instastack deployments `kms-envelope.service.ts`
(encryption-context binding), 2026-05-23. Both services store customer
secrets and independently converged on this shape; promoted to a global
rule because any future service persisting third-party secrets hits the
identical design.
