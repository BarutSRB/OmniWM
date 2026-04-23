#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/Scripts/build-common.sh"
omniwm_load_build_metadata "$ROOT_DIR"

CONFIG="${1:-release}"
omniwm_require_swiftpm_config "$CONFIG"

CONFIG_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
ARM64_BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIG"
X86_64_BUILD_DIR="$ROOT_DIR/.build/x86_64-apple-macosx/$CONFIG"
UNIVERSAL_BUILD_DIR="$ROOT_DIR/.build/apple/Products/$CONFIG_CAPITALIZED"

omniwm_verify_ghostty_archive
omniwm_require_zig_version
omniwm_setup_ghostty_library_path

echo "Using Zig $(zig version)"
echo "Using Ghostty archive digest $(omniwm_actual_ghostty_archive_sha256)"
echo "Building OmniWM ($CONFIG) for arm64..."
swift build -c "$CONFIG" --arch arm64
echo "Building OmniWM ($CONFIG) for x86_64..."
swift build -c "$CONFIG" --arch x86_64

omniwm_require_command lipo
omniwm_require_command ditto
omniwm_require_file "$ARM64_BUILD_DIR/OmniWM"
omniwm_require_file "$X86_64_BUILD_DIR/OmniWM"
omniwm_require_file "$ARM64_BUILD_DIR/omniwmctl"
omniwm_require_file "$X86_64_BUILD_DIR/omniwmctl"
omniwm_require_file "$ARM64_BUILD_DIR/OmniWM_OmniWM.bundle/kernels-built.txt"

rm -rf "$UNIVERSAL_BUILD_DIR"
mkdir -p "$UNIVERSAL_BUILD_DIR"

echo "Assembling universal executables..."
lipo -create -output "$UNIVERSAL_BUILD_DIR/OmniWM" \
  "$ARM64_BUILD_DIR/OmniWM" \
  "$X86_64_BUILD_DIR/OmniWM"
lipo -create -output "$UNIVERSAL_BUILD_DIR/omniwmctl" \
  "$ARM64_BUILD_DIR/omniwmctl" \
  "$X86_64_BUILD_DIR/omniwmctl"
ditto "$ARM64_BUILD_DIR/OmniWM_OmniWM.bundle" "$UNIVERSAL_BUILD_DIR/OmniWM_OmniWM.bundle"

echo "Universal products are available in $UNIVERSAL_BUILD_DIR"
