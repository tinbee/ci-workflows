# The local review image: the Claude CLI, git and this directory's prompt files, nothing from
# the host. No ~/.claude is copied in, so the session sees none of the developer's global
# rules, memory or hooks. Build context: review/ (the parent of this directory).
FROM node:24-slim

ARG CLAUDE_CODE_VERSION=2.1.311
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

ENV DISABLE_AUTOUPDATER=1
COPY --chmod=755 assemble.sh /opt/review/assemble.sh
COPY core.md /opt/review/core.md
COPY local/return-structured.md local/schema.json /opt/review/local/
COPY --chmod=755 local/review.sh /opt/review/local/review.sh

USER node
ENTRYPOINT ["/opt/review/local/review.sh"]
