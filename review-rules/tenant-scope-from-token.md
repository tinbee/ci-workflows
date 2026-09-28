# Tenant scope is authorized per request, never trusted from the request

In multi-tenant services, the tenant an endpoint operates on must be
established by the server from the authenticated principal — never
taken from a body, query or header value the caller supplies and
trusted as-is. A tenant id that is merely echoed back would let a
caller probe other tenants by guessing UUIDs, especially when the
user belongs to more than one.

A path selector is not by itself a violation. In Instastack's Go
control plane, for example, the tenant is *selected* by the
`/v1/tenants/{tenant}` path slug and *authorized* on every request by
loading the caller's membership row (`internal/cp/api/tenant_scope.go`
in that service); handlers then scope every query with `sc.Tenant.ID`. A
path selector re-authorized that way is the intended shape. The
violation is any tenant identifier — path, query, body or stored state —
that reaches a query without that per-request check.

This rule was learned painfully across Copilot review rounds on
PR #33: I shipped three GitHub install endpoints that accepted
free `orgId` params (`@Query("orgId")` on `mintState`,
`@Param("orgId")` on `listInstallations`, `pending.orgId` from
Redis state on `installCallback`). All three were tenant-scope
holes. The fix was to standardize on token-derived scope.

## The principle

The authenticated principal plus a server-side authorization lookup is
the only source of truth for "which tenant is this caller acting in".
In the NestJS examples below that lookup was baked into the JWT's
tenant claim; in the Go control plane above it is the membership row. Any
other tenant identifier — query param, request body field, value stored
in Redis state minted earlier — is either redundant (drop it) or
potentially inconsistent (check it against the authorized tenant).

## Three patterns

### Pattern 1 — drop the redundant param, derive from token

When the param exists only to identify which org the operation
is for, drop it. The JWT already carries it.

```ts
// BAD — orgId in query param
@Post("install-state")
async mintState(
  @PrincipalDecorator() principal: Principal | undefined,
  @Query("orgId") orgId: string | undefined,
) {
  if (!orgId) throw new BadRequestException("orgId required");
  // ... use orgId without checking it against token
}

// GOOD — orgId from token
@Post("install-state")
async mintState(
  @PrincipalDecorator() principal: Principal | undefined,
) {
  const orgId = requireTenantId(principal);
  // ... use orgId, guaranteed to be the caller's actual tenant
}
```

Same pattern for path params:

```ts
// BAD — orgId in path
@Get("installations/:orgId")
async list(@Param("orgId") orgId: string) { ... }

// GOOD — orgId from token, route shape simplified
@Get("installations")
async list(@PrincipalDecorator() principal: Principal | undefined) {
  const orgId = requireTenantId(principal);
  ...
}
```

### Pattern 2 — assert a stored orgId matches the token

When the operation references a stored orgId (Redis state from
an earlier mint, a foreign-key in a request body, etc.), don't
just trust the stored value — assert it matches the principal's
current tenant.

```ts
// BAD — pending.orgId trusted blindly
const pending = await this.service.resolveState(state);
await this.authz.requireOrgAdmin(principal, authHeader, pending.orgId);

// GOOD — pending.orgId asserted against token first
const pending = await this.service.resolveState(state);
assertTenant(principal, pending.orgId);
await this.authz.requireOrgAdmin(principal, authHeader, pending.orgId);
```

Why this matters: a user can have delegated tokens for multiple
orgs over time. If they minted state while acting in org A and
then completed the flow while acting in org B, the stored
`pending.orgId` (org A) would be used to scope the install — but
the user is now operating in org B's context. `assertTenant`
catches this within-user cross-tenant attack that the user-id
check (state binding) doesn't.

### Pattern 3 — for service-to-service calls, scope is part of the request

When the caller is a service token (no user context), there's no
principal-tenant to derive from — the caller has to pass the
target org. Validate it as input (UUID format, existence) but
treat it as data, not as authz.

```ts
// Service-to-service: orgId IS the input, no principal tenant
@AllowPrincipals(TOKEN_TYPE.service)
@Post("internal/sweep-org")
async sweep(@Body() dto: { organizationId: string }) {
  // dto.organizationId is just data; the auth comes from the
  // service token's permissions, not from a principal-tenant.
}
```

This is the exception. For user/delegated-token endpoints, always
Pattern 1 or Pattern 2.

## The helpers

In a service that adopts this rule, two helpers do all the work:

```ts
// Throws ForbiddenException unless the principal is user/delegated
// AND has a tenantId claim. Returns that tenantId.
function requireTenantId(principal: Principal | undefined): string;

// Throws ForbiddenException if the supplied organizationId does
// not match the principal's tenantId. Use when validating a
// stored/passed orgId against the token.
function assertTenant(principal: Principal | undefined, organizationId: string): void;
```

Reference implementation in instastack's NestJS deployments service:
`services/deployments/src/common/tenant.ts`. The Go equivalent, in
Instastack's control plane, is `tenantScope` in
`internal/cp/api/tenant_scope.go`: slug → tenant → membership, resolved
once per request, with a vague 404 for both "no such tenant" and "not a
member".

## Lint heuristic

Flag for review during PR review: any controller method that
takes `@Query("orgId")` or `@Param("orgId")` (or equivalent
tenant-key params). Either the method is using the helper to
narrow it (which makes the param redundant — drop it), or it's
not narrowing it (security hole — fix it). Either way, action.

## Tenant-scope counts/aggregates too

Closely related and frequently missed: when an endpoint returns
a count or aggregate over tenant-scoped resources, scope the
query — not just the existence check.

```ts
// BAD — existence check is tenant-scoped, count isn't
const installation = await prisma.githubInstallation.findFirst({
  where: { installationId, organizationId }, // scoped ✓
});
if (!installation) throw new NotFoundException();

const affectedAppCount = await prisma.appRepo.count({
  where: { installationId }, // NOT scoped ✗ — leaks cross-tenant rows
});

// GOOD — count is also tenant-scoped
const affectedAppCount = await prisma.appRepo.count({
  where: {
    installationId,
    app: { stack: { organizationId } }, // scoped ✓
  },
});
```

Why: even with strict prevent-cross-tenant-write rules going
forward, historical data or test fixtures may contain
cross-tenant rows. A count that returns "7 affected apps" when
only 3 belong to the requesting org is a data leak via the
response body.

## Why this is so easy to miss

Three reasons:

1. **It works in single-tenant test fixtures.** A spec with one
   user, one org, and one orgId param looks correct — but the
   test isn't exercising the cross-tenant case.
2. **The orgId param "looks like documentation"** — it tells the
   reader "this endpoint operates on an org." But the reader
   already knows that from the JWT and the route name; the
   param adds no information.
3. **Path-based orgId looks RESTful.** `/orgs/:orgId/things` is
   a familiar shape. But unless the user is acting on behalf of
   that orgId via the JWT, the path is lying.

The fix is to internalize: **the JWT is the only source of truth
for which org I'm in right now.** Any param that says otherwise
is either redundant or suspicious.

## Source

Distilled from Copilot review rounds 2 + 3 on instastack PR #33
(2026-04-29). Four threads on the same theme produced this
generalization.
