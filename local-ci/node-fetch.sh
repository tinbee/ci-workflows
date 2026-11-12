#!/usr/bin/env bash
# Runs in the local-ci fetch container (node.Dockerfile), the one container that reaches the npm
# registry: fills the repository's package caches, in /pnpm, from the commit's lockfiles and
# package.json files. It is given no other file of the commit, and runs no lifecycle script and
# no .pnpmfile, so nothing of the commit or its dependencies runs where the registry is
# reachable: npm accepts a publish from anyone with a token, so code here could otherwise send
# the repository out.
#
# Not .npmrc, which can name programs for pnpm to run (`git=`), and no file of this stays
# executable: a manifest could otherwise be both the program and the thing it reads.
# pnpm-workspace.yaml is given, because the install needs what it configures (packages,
# catalogs, overrides). Were any of it to run code anyway, this container holds only these
# files, so they are all such code could send.
#
#   FETCH_PNPM=1  the pnpm store and metadata cache, from pnpm-lock.yaml (a node-pnpm-ci job).
#   FETCH_NPM=1   an npm cache (an inline job that runs npm itself): every package-lock.json,
#                 as `npm ci` installs it, and the dependencies of every publishable package
#                 (not private, named), which a packed tarball of it brings and npm resolves
#                 from their ranges, as it would for whoever installs that package.
#
# stdin: a tar of the manifests (every package.json, pnpm-lock.yaml, pnpm-workspace.yaml,
# package-lock.json).
set -euo pipefail

mkdir -p ~/fetch
# macOS tar adds xattr headers (com.apple.provenance) that GNU tar warns about, once per file.
tar --warning=no-unknown-keyword -xf - -C ~/fetch
chmod -R a-x,a+X ~/fetch
cd ~/fetch

if [ "${FETCH_PNPM:-0}" = 1 ]; then
  pnpm install --frozen-lockfile --ignore-scripts --ignore-pnpmfile --store-dir /pnpm/store --cache-dir /pnpm/cache
fi

if [ "${FETCH_NPM:-0}" = 1 ]; then
  npm_flags=(--ignore-scripts --no-audit --no-fund --loglevel=error --cache /pnpm/npm --update-notifier=false)
  while IFS= read -r -d '' lock; do
    echo "npm ci: ${lock#./}"
    (cd "$(dirname "$lock")" && npm ci "${npm_flags[@]}")
  done < <(find . -name package-lock.json -not -path '*/node_modules/*' -print0)
  # name@range, allow-listed, since both come from the commit: a name npm would accept, and a
  # semver range or dist-tag (workspace:, file:, link:, git and URL specs are not the
  # registry's to resolve, and anything else could be read as an option). `--` as well.
  mapfile -t specs < <(find . -name package.json -not -path '*/node_modules/*' -print0 \
    | xargs -0 jq -r 'select((.private // false) != true and (.name // "") != "")
        | .dependencies // {} | to_entries[]
        | select(.key | test("^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$"))
        | select(.value | type == "string" and test("^[0-9A-Za-z.*^~<>=| +-]+$"))
        | "\(.key)@\(.value)"' | sort -u)
  if [ "${#specs[@]}" -gt 0 ]; then
    echo "npm cache add: ${specs[*]}"
    npm cache add "${npm_flags[@]}" -- "${specs[@]}"
  fi
fi
