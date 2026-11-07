#!/bin/bash
# Copies the vendored libjxl closure into the app bundle and signs each dylib
# before Xcode signs the app. Install names are already @rpath.
set -euo pipefail

: "${TARGET_BUILD_DIR:?}"
: "${WRAPPER_NAME:?}"
: "${SRCROOT:?}"

DEST="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Frameworks"
SRC="${SRCROOT}/Vendor/libjxl/lib"
mkdir -p "${DEST}"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="-"
fi

names=(
    libjxl.0.12.dylib
    libjxl_cms.0.12.dylib
    libjxl_threads.0.12.dylib
    libhwy.1.dylib
    libbrotlidec.1.dylib
    libbrotlicommon.1.dylib
    libbrotlienc.1.dylib
    liblcms2.2.dylib
)

for name in "${names[@]}"; do
    if [[ -e "${DEST}/${name}" ]]; then
        chmod u+w "${DEST}/${name}"
    fi
    cp -f "${SRC}/${name}" "${DEST}/${name}"
    chmod u+w "${DEST}/${name}"
    codesign --force --sign "${IDENTITY}" --timestamp=none "${DEST}/${name}"
done
