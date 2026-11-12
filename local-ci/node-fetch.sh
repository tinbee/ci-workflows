#!/usr/bin/env bash
# Runs in the local-ci fetch container (node.Dockerfile), the one container that reaches the npm
# registry: fills the repository's pnpm store and metadata cache, in /pnpm, from the commit's
# lockfile and package.json files. It is given no other file of the commit, and runs no
# lifecycle script and no .pnpmfile, so nothing of the commit or its dependencies runs where
# the registry is reachable: npm accepts a publish from anyone with a token, so code here could
# otherwise send the repository out.
#
# Not .npmrc, which can name programs for pnpm to run (`git=`), and no file of this stays
# executable: a manifest could otherwise be both the program and the thing it reads.
# pnpm-workspace.yaml is given, because the install needs what it configures (packages,
# catalogs, overrides). Were any of it to run code anyway, this container holds only these
# files, so they are all such code could send.
#
# stdin: a tar of the manifests (every package.json, pnpm-lock.yaml, pnpm-workspace.yaml).
set -euo pipefail

mkdir -p ~/fetch
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C ~/fetch
chmod -R a-x,a+X ~/fetch
cd ~/fetch
pnpm install --frozen-lockfile --ignore-scripts --ignore-pnpmfile --store-dir /pnpm/store --cache-dir /pnpm/cache
