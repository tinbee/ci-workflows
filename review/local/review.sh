#!/usr/bin/env bash
# Runs inside the local review container (review.Dockerfile): one cold-context review of
# $BASE...$SHA. The CLI's JSON result goes to stdout and everything else to stderr.
#
# stdin: a tar of tree/ (the files of $SHA), pr.diff and files.txt ($BASE...$SHA, made on the
#        host, so a shallow clone works), review-rules/ and project_context.txt.
# env:   SHA, BASE, MODEL, EFFORT, CLAUDE_CODE_OAUTH_TOKEN; PROJECT_RULES optional.
set -euo pipefail

in=/tmp/in
mkdir -p "$in"
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C "$in"

mkdir -p ~/work
mv "$in/tree" ~/work/repo
cd ~/work/repo

# The same layout claude-review.yml gives the cloud review, so the prompt's paths hold in both.
# The commit is untrusted and may carry its own copies of these paths (a fake rules index, a
# pr.diff symlinked somewhere). Remove them first, so the trusted copies replace them; with
# the directory already present, `mv` would nest the real rules beside the commit's.
for p in .shared-review-rules .review-context; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    echo "the commit has its own $p; replacing it" >&2
    rm -rf -- "$p"
  fi
done
mkdir -p .shared-review-rules .review-context
mv "$in/review-rules" .shared-review-rules/review-rules
mv "$in/pr.diff" "$in/files.txt" .review-context/
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
