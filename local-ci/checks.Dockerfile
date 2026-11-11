# The local-ci checks image: Go at the commit's go.mod version plus the tools its go-ci inputs
# ask for, at the versions go-ci.yml's actions would install. run.sh reads the build args
# from the commit's ci.yml and go.mod. Build context: local-ci/.
#
# Tools are installed here, at BUILD time, with network. The container that runs the commit
# has no credential and reaches only the hosts in checks-allow.txt.
ARG GO_VERSION
FROM golang:${GO_VERSION}

ARG BUF=false
ARG SQLC_VERSION=
ARG GOLANGCI_VERSION=
ARG GOVULNCHECK=true

RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*
# buf-action with setup_only installs the latest buf.
RUN if [ "$BUF" = true ]; then GOBIN=/usr/local/bin go install github.com/bufbuild/buf/cmd/buf@latest; fi
# setup-sqlc downloads this release archive.
RUN if [ -n "$SQLC_VERSION" ]; then \
      curl -fsSL "https://downloads.sqlc.dev/sqlc_${SQLC_VERSION}_linux_$(dpkg --print-architecture).tar.gz" \
        | tar -xz -C /usr/local/bin sqlc; \
    fi
# `v2.14` is a version query, the newest v2.14.x, as golangci-lint-action resolves it.
RUN case "$GOLANGCI_VERSION" in \
      "") ;; \
      v1*) GOBIN=/usr/local/bin go install "github.com/golangci/golangci-lint/cmd/golangci-lint@${GOLANGCI_VERSION}" ;; \
      *) GOBIN=/usr/local/bin go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_VERSION}" ;; \
    esac
RUN if [ "$GOVULNCHECK" = true ]; then GOBIN=/usr/local/bin go install golang.org/x/vuln/cmd/govulncheck@latest; fi

# local: a toolchain mismatch should fail, not download.
ENV GOTOOLCHAIN=local
RUN useradd -m ci && mkdir -p /home/ci/.cache/go-build && chown -R ci /home/ci
COPY --chmod=755 go-checks.sh /opt/local-ci/go-checks.sh

USER ci
ENTRYPOINT ["/opt/local-ci/go-checks.sh"]
