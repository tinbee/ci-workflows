#!/usr/bin/env bash
# Prints a reviewer prompt: core.md, then one ending (publish-pr.md for claude-review.yml,
# local/return-structured.md for local-ci), with the placeholders filled in.
#
#   assemble.sh <ending.md>
#   env: PROJECT_CONTEXT, PROJECT_RULES (default docs/review-rules/README.md), REPO, PR
#
# One assembler for both callers, so the two reviews cannot be told different things.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ending="${1:?usage: assemble.sh <ending.md>}"
[ -f "$ending" ] || ending="$here/$ending"
[ -f "$ending" ] || { echo "assemble.sh: no ending file $1" >&2; exit 1; }

# `&` in a replacement would expand to the match under bash 5.2's patsub_replacement.
shopt -u patsub_replacement 2>/dev/null || true
prompt="$(cat "$here/core.md")"$'\n\n'"$(cat "$ending")"

# REPO and PR have no sensible empty value: the publish ending would tell the model to post
# to `repos//pulls//reviews`. PROJECT_CONTEXT may be empty (the workflow input defaults to "").
for name in REPO PR; do
  case "$prompt" in
    *"{{$name}}"*)
      [ -n "${!name:-}" ] || { echo "assemble.sh: $name is empty but the prompt uses it" >&2; exit 1; }
      ;;
  esac
done

prompt="${prompt//'{{PROJECT_CONTEXT}}'/${PROJECT_CONTEXT:-}}"
prompt="${prompt//'{{PROJECT_RULES}}'/${PROJECT_RULES:-docs/review-rules/README.md}}"
prompt="${prompt//'{{REPO}}'/${REPO:-}}"
prompt="${prompt//'{{PR}}'/${PR:-}}"

# A placeholder left unfilled is a prompt that points the model at a literal `{{REPO}}`.
case "$prompt" in
  *'{{'[A-Z_]*'}}'*)
    echo "assemble.sh: unfilled placeholder in the prompt" >&2
    exit 1
    ;;
esac
printf '%s\n' "$prompt"
