# The local-ci image for a node-pnpm-ci.yml job, and for a job ci.yml writes inline: Node at the
# version setup-node would install (the commit's node_version_file, else node_version), pnpm at
# package.json's packageManager when the job sets pnpm up, and Go at its go.mod's version when
# it sets Go up, as pnpm/action-setup and setup-go would. run.sh reads all three from the
# commit. Build context: local-ci/.
#
# The same image runs the fetch (node-fetch.sh, the one container that reaches the npm
# registry, and runs nothing of the commit's) and the checks (node-checks.sh, inline-checks.sh,
# which reach only the hosts in checks-allow.txt and install offline). git and curl are in the
# bookworm image.
ARG NODE_VERSION
FROM node:${NODE_VERSION}-bookworm

ARG PNPM_VERSION=
ARG GO_VERSION=
# yq is mikefarah's, as GitHub's runners have it (ruleset drift guards call it); Debian's `yq`
# package is a different program with a different syntax.
RUN apt-get update && apt-get install -y --no-install-recommends jq shellcheck && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_$(dpkg --print-architecture)" -o /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq \
  && if [ -n "$PNPM_VERSION" ]; then npm install -g "pnpm@${PNPM_VERSION}"; fi \
  && if [ -n "$GO_VERSION" ]; then \
       curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" | tar -xz -C /usr/local; \
     fi

# local: a toolchain mismatch should fail, not download. GOPATH is the checks user's own.
ENV PATH=/usr/local/go/bin:/home/node/go/bin:$PATH GOTOOLCHAIN=local GOPATH=/home/node/go

COPY --chmod=755 node-checks.sh inline-checks.sh node-fetch.sh /opt/local-ci/

USER node
ENTRYPOINT ["/opt/local-ci/node-checks.sh"]
