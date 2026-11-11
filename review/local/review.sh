#!/usr/bin/env bash
# Runs inside the local review container (review.Dockerfile): one cold-context review of
# $BASE...$SHA. The CLI's JSON result goes to stdout and everything else to stderr.
#
# stdin: a tar of repo.bundle (refs to $SHA and $BASE), review-rules/ and project_context.txt.
# env:   SHA, BASE, MODEL, EFFORT, CLAUDE_CODE_OAUTH_TOKEN; PROJECT_RULES optional.
set -euo pipefail

in=/tmp/in
mkdir -p "$in"
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C "$in"

mkdir -p ~/work/repo
cd ~/work/repo
git init -q
git fetch -q "$in/repo.bundle" '+refs/*:refs/bundle/*'
git -c advice.detachedHead=false checkout -q "$SHA"

# The same layout claude-review.yml gives the cloud review, so the prompt's paths hold in both.
mkdir -p .shared-review-rules .review-context
mv "$in/review-rules" .shared-review-rules/
git diff "$BASE...$SHA" > .review-context/pr.diff
git diff --name-only "$BASE...$SHA" > .review-context/files.txt
echo "reviewing $(wc -l < .review-context/pr.diff) diff lines across $(wc -l < .review-context/files.txt) files" >&2

prompt="$(PROJECT_CONTEXT="$(cat "$in/project_context.txt")" /opt/review/assemble.sh local/return-structured.md)"

# The CLI runs inside the commit under review, and that commit is untrusted: its own
# .claude/settings.json (hooks, enableAllProjectMcpServers, plugins) or .mcp.json would run
# commands in the one container that holds the token, whatever --allowedTools says. A test
# commit's .mcp.json did exactly that (tinbee/woahbar#10). So: user settings only (the image
# has none), no MCP servers but an empty explicit set, and no hooks.
exec claude -p "$prompt" \
  --setting-sources user \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --settings '{"disableAllHooks":true}' \
  --model "$MODEL" --effort "$EFFORT" --max-turns 200 \
  --output-format json --json-schema "$(cat /opt/review/local/schema.json)" \
  --allowedTools "Read,Glob,Grep" \
  --disallowedTools "Agent,Task,Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch" \
  --permission-mode dontAsk
