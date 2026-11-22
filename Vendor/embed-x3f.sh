#!/bin/bash
# Copies the CPU-only X3F converter into the app and signs it.
# A missing binary leaves the app able to open the embedded preview.
set -euo pipefail

: "${TARGET_BUILD_DIR:?}"
: "${WRAPPER_NAME:?}"
: "${SRCROOT:?}"

APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
SRC="${SRCROOT}/Vendor/x3fuse/bin/zimager-x3f"
DEST="${APP}/Contents/MacOS/zimager-x3f"
RES="${APP}/Contents/Resources"
mkdir -p "${RES}"
cp -f "${SRCROOT}/Vendor/x3fuse/LICENSE" "${RES}/x3fuse-LICENSE.txt"
cp -f "${SRCROOT}/Vendor/x3fuse/NOTICE" "${RES}/x3fuse-NOTICE.txt"

if [[ ! -x "${SRC}" ]]; then
    echo "warning: zimager-x3f is not built; X3F files open from the embedded preview" >&2
    exit 0
fi

mkdir -p "$(dirname "${DEST}")"
if [[ -e "${DEST}" ]]; then
    chmod u+w "${DEST}"
fi
cp -f "${SRC}" "${DEST}"
chmod 755 "${DEST}"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="-"
fi
codesign --force --sign "${IDENTITY}" --timestamp=none "${DEST}"
