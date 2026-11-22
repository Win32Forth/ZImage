#!/bin/bash
# Builds the CPU-only X3F converter and copies it to Vendor/x3fuse/bin.
# Requires Rust 1.88 or newer. Does not enable the gpu feature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export LIBCLANG_PATH="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/lib"
export SDKROOT="${DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export PATH="${HOME}/.cargo/bin:${PATH}"

cd "${ROOT}"
cargo build --release --locked
mkdir -p "${ROOT}/bin"
cp -f "${ROOT}/target/release/zimager-x3f" "${ROOT}/bin/zimager-x3f"
chmod 755 "${ROOT}/bin/zimager-x3f"
