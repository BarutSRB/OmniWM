#!/bin/sh
set -eu

CONFIG=${1:-debug}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ZIG_ROOT="$ROOT_DIR/Zig/omniwm_kernels"
OUTPUT_DIR="$ROOT_DIR/.build/zig-kernels"
ARM64_DIR="$OUTPUT_DIR/arm64"
X86_64_DIR="$OUTPUT_DIR/x86_64"
LIB_DIR="$OUTPUT_DIR/lib"
UNIVERSAL_LIB="$LIB_DIR/libomniwm_kernels.a"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/build-common.sh"
omniwm_load_build_metadata "$ROOT_DIR"
omniwm_require_zig_build_config "$CONFIG"
omniwm_require_zig_version
omniwm_require_command lipo
omniwm_require_command ranlib
omniwm_require_file "$ZIG_ROOT/build.zig"
omniwm_require_file "$ZIG_ROOT/src/root.zig"

OPTIMIZE=$(omniwm_zig_optimize_for_config "$CONFIG")
ARM64_TARGET=$(omniwm_zig_target_for_arch arm64)
X86_64_TARGET=$(omniwm_zig_target_for_arch x86_64)

rm -rf "$ARM64_DIR" "$X86_64_DIR"
mkdir -p "$LIB_DIR"

echo "Building OmniWM Zig kernels (arm64, $OPTIMIZE) with Zig $OMNIWM_ACTUAL_ZIG_VERSION..."
(
  cd "$ZIG_ROOT"
  zig build --summary none --prefix "$ARM64_DIR" -Dtarget="$ARM64_TARGET" -Doptimize="$OPTIMIZE"
)

echo "Building OmniWM Zig kernels (x86_64, $OPTIMIZE) with Zig $OMNIWM_ACTUAL_ZIG_VERSION..."
(
  cd "$ZIG_ROOT"
  zig build --summary none --prefix "$X86_64_DIR" -Dtarget="$X86_64_TARGET" -Doptimize="$OPTIMIZE"
)

echo "Creating universal OmniWM Zig kernel archive..."
lipo -create \
  "$ARM64_DIR/lib/libomniwm_kernels.a" \
  "$X86_64_DIR/lib/libomniwm_kernels.a" \
  -output "$UNIVERSAL_LIB"

ranlib "$UNIVERSAL_LIB"

echo "Built $UNIVERSAL_LIB"
