# App boundaries: consume the contract, keep shared code generic

Tin Bee apps use each other (Instastack and woahbar use Foliot for workflows, woahbar-ios
uses woahbar's API) and share libraries (gokit, ci-workflows). Both relationships fail
silently when a boundary leaks: the code works today and breaks the day the other side
changes something it never promised.

## A consumer builds only against what the provider publishes

The provider's contract is its OpenAPI spec, its SDK, its documented webhooks and docs.
Flag a diff in a consumer that:

- relies on a status code's meaning, a limit, a URL shape, a field name, a retry or timing
  behaviour the provider's contract does not state;
- hand-builds a request the provider's SDK already offers, or reaches past the SDK into a
  package it does not export;
- carries a comment like "Foliot actually returns …" or "the server does X internally":
  knowledge that came from reading the provider's source;
- works around a missing capability instead of naming the contract gap.

The fix is an issue on the provider's repository describing what the consumer needs, not
a workaround here. Ask for the issue link in the PR description.

## A provider contains nothing for one consumer

Flag a diff in a provider that adds a consumer's names, types, tables or special cases to
its code or its contract. A capability one customer needs is added in a form any customer
could use, or not at all.

## Shared libraries stay generic

Flag a diff in gokit, ci-workflows or any shared library that adds:

- an app's name, type, table, flag or behaviour;
- an option, branch or input that exists only because one consumer asked for it and makes
  no sense without that consumer in mind.

A consumer's need belongs in the library only when it reads as a sensible feature with no
app in mind. Otherwise it belongs in the app, and the PR should say why it could not be
made generic.

## Shared libraries do the work; apps make the decisions

A shared library does what it is asked once and returns the result or the error,
unchanged. What to do about the result is the app's decision: retrying, backing off,
falling back, failing open or closed, serving something stale. Flag a diff in a shared
library that:

- re-runs, retries or falls back by itself, or swallows an error, by default;
- adds a policy default an app has to switch off (an option whose usual value is "off"
  is the sign: `TxAttempts(1)` passed in a dozen places);
- picks an outcome for a failure on the app's behalf (allow on store error, trust a
  cached credential past its expiry) without the app having chosen it.

Fine: guards that protect the library itself (refusing an invalid setting, bounding a
read, a timeout on a call), classifiers that let the caller decide
(`pgkit.Retryable(err)`), and a shared policy offered as an option the caller passes
(`pgkit.TxRetries(n)`). The test, for anything that is not one of those guards: can a caller
who reads only the function's name and arguments predict what it does after a failure?
If the honest answer needs "unless…" (it runs your function again, it falls back, it
swallows that error), the library is deciding for the app.

A shared rate limiter is the worked case: rate-limiting-architecture.md wants requests to
fail open on a store error, and that choice is made in the app's wiring (a required
`OnStoreError` setting), not by the library's default.

Source: gokit's `pgkit.Tx` re-ran the caller's function up to 5 times after a Postgres
conflict, by default. Foliot opted out in 10 places and Instastack in 2, and two
"decisions" reached the user that only existed because of the default (2026-11-23).

## Source

Fleet rule set on 2026-11-19, generalised from the per-repo contract sections that
Instastack, woahbar, woahbar-ios, Foliot and gokit each carried separately.
