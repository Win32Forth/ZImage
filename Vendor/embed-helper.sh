#!/bin/bash
# Builds the Linux helper binaries into the app bundle. ZImager copies them onto a Synology share.
set -euo pipefail

: "${TARGET_BUILD_DIR:?}"
: "${WRAPPER_NAME:?}"
: "${SRCROOT:?}"

export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/bin:/bin:${PATH:-}"
if ! command -v go >/dev/null 2>&1; then
  echo "Go is required to build the Synology helper." >&2
  exit 1
fi

DEST="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Resources/Helper"
mkdir -p "${DEST}"
cd "${SRCROOT}/Helper"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "${DEST}/zimage-helper-aarch64" ./cmd/zimage-helper
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "${DEST}/zimage-helper-x86_64" ./cmd/zimage-helper
