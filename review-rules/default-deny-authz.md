# Default-deny authorization + CI decorator-coverage gate

In any service with a global auth guard, the dangerous failure mode is
not a wrong decorator — it's a **missing** one. A new route that forgets
its auth decorator must fail *closed* (admit nothing privileged), and CI
must fail the build if any route lacks an explicit auth declaration.
"We'll remember to add the guard" is not a control.

Learned on instastack's NestJS services (`packages/auth` plus
`collect-principal-coverage.ts` — another service, not the repo you are
reviewing). Complements [`tenant-scope-from-token.md`](tenant-scope-from-token.md)
(that rule is about *which tenant*; this rule is about *whether the
route is gated at all*).

## Two-axis decorator model

Separate "who is this endpoint *for*" from "who may *act*":

- `@Audience(...)` — the intended consumer (documentation + token `aud`
  matching).
- `@AllowPrincipals(...types)` — which principal *kinds* may call
  (`user`, `delegated`, `service`).
- `@RequireRoles(...)` / `@RequireScopes(...)` / `@RequireSudo()` —
  finer gates layered on top.
- `@Public()` — explicit opt-out (webhooks, health, sign-in).

## Default-deny semantics

The global `APP_GUARD` (`PrincipalGuard`) enforces: **a route with no
`@AllowPrincipals` admits ONLY `user`/`delegated`, never `service`
tokens.** Service tokens bypass role/active-org gates, so they must be
*explicitly* allow-listed per route — never granted by omission. A route
with neither `@AllowPrincipals` nor `@Public` is therefore locked to
interactive users by default, never to machine callers.

```ts
// principal.guard.ts (sketch)
const allowed = reflector.get(ALLOW_PRINCIPALS, handler);
if (!allowed) {
  // default-deny: omitting the decorator does NOT admit service tokens
  if (principal.type === "service") throw new ForbiddenException();
}
// scopes only constrain service principals; users/delegated pass through
if (principal.type === "service") assertScopes(principal, requiredScopes);
```

Layer order matters: `PrincipalGuard` first (populates `req.principal`),
tenant/active-org guard second (reads it). Wire both as `APP_GUARD`.

## The CI coverage gate (the load-bearing part)

A build-time script walks every controller's route metadata and **fails
CI** for any route missing both `@AllowPrincipals` and `@Public`:

```ts
// collect-principal-coverage.ts (sketch) — run in CI
for (const { controller, handler, method, path } of allRoutes()) {
  const hasAllow = Reflect.getMetadata(ALLOW_PRINCIPALS, handler);
  const isPublic = Reflect.getMetadata(IS_PUBLIC, handler);
  if (!hasAllow && !isPublic) {
    failures.push(`${method} ${path} (${controller.name}.${handler.name}) ` +
      `has neither @AllowPrincipals nor @Public`);
  }
}
if (failures.length) { console.error(failures.join("\n")); process.exit(1); }
```

This is the difference between "default-deny in principle" and
"default-deny that survives the next hurried PR." Without the gate, a
forgotten decorator on a route that *happens* to admit users is invisible
until a pentest. A sibling script (`collect-bypass-routes.ts`) can
inventory every `@Public` route so the bypass surface is reviewable.

## Adjacent rules (already captured, listed for the full picture)

- **POST-as-RPC reads return `@HttpCode(200)`** (permission check,
  search, validate) — not 201.
- **State-machine fields use transition endpoints**, never PATCH.
- **Authz is never cached in the token** — look up per request
  ([`tenant-scope-from-token.md`](tenant-scope-from-token.md)). Even 60s of
  staleness leaves a demoted admin acting as admin.
- **No `_unused` "future RBAC" params** — they're either load-bearing
  or a gap.

## Traps

1. **Default-admit by omission.** A guard that treats "no decorator" as
   "allow all" is the inverse of this rule and the most common mistake.
2. **Gate exists, CI check doesn't.** The decorators are only as good as
   the coverage script that proves every route has one.
3. **`@Public` sprawl.** Each `@Public` is an un-gated entry point;
   inventory them and verify each (webhook signature, health, etc.).
4. **Service tokens admitted by a generic guard** that only checks
   "is authenticated" — service principals need explicit allow + scopes.

## Lint heuristic

For any service with a global auth guard:
1. Confirm a CI step fails on routes missing `@AllowPrincipals`/`@Public`.
2. Grep new controllers in a PR for handlers without an auth decorator.
3. Confirm the global guard's no-decorator branch denies service tokens.

## Source

Distilled from instastack `packages/auth` (PrincipalGuard default-deny,
audit finding M1) + `collect-principal-coverage.ts` CI gate, 2026-05-23.
Both of those files live in that predecessor service; neither is in the
repository you are reviewing, so read the paths as provenance rather than
as somewhere to go looking. Promoted to global because every
multi-service codebase grows routes faster than reviewers can remember to
gate them — the CI coverage check is the only durable enforcement.
