# The local-ci image for a node-pnpm-ci.yml job: Node at the version setup-node would install
# (the commit's node_version_file, else node_version) and pnpm at package.json's
# packageManager, as pnpm/action-setup reads it. run.sh reads both from the commit. Build
# context: local-ci/.
#
# The same image runs the fetch (node-fetch.sh, the one container that reaches the npm
# registry, and runs nothing of the commit's) and the checks (node-checks.sh, which reaches
# only the hosts in checks-allow.txt and installs offline). git is in the bookworm image.
ARG NODE_VERSION
FROM node:${NODE_VERSION}-bookworm

ARG PNPM_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/* \
  && npm install -g "pnpm@${PNPM_VERSION}"

COPY --chmod=755 node-checks.sh node-fetch.sh /opt/local-ci/

USER node
ENTRYPOINT ["/opt/local-ci/node-checks.sh"]
