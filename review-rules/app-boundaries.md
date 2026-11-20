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

## Source

Fleet rule set on 2026-11-19, generalised from the per-repo contract sections that
Instastack, woahbar, woahbar-ios, Foliot and gokit each carried separately.
