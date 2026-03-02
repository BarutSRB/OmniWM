#!/usr/bin/env bash
# build-zig.sh — compile zig/omni_layout.zig into .build/zig/libomni_layout.a
#
# Default behavior builds a universal macOS static library (arm64 + x86_64).
# Set ZIG_TARGET to produce a single-arch library:
#   ZIG_TARGET=x86_64-macos ./build-zig.sh
set -euo pipefail

OUT_DIR=".build/zig"
OUT_LIB="${OUT_DIR}/libomni_layout.a"
SRC="zig/omni_layout.zig"
REQUESTED_TARGET="${ZIG_TARGET:-}"

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found in PATH — install from https://ziglang.org/download/" >&2
    exit 1
fi

build_one() {
    local target="$1"
    local output="$2"
    echo "▸ zig build-lib  target=${target}  out=${output}"
    zig build-lib \
        -O ReleaseFast \
        -target "${target}" \
        -femit-bin="${output}" \
        -fno-emit-h \
        "${SRC}"
}

mkdir -p "${OUT_DIR}"

if [[ -n "${REQUESTED_TARGET}" ]]; then
    build_one "${REQUESTED_TARGET}" "${OUT_LIB}"
    if command -v lipo >/dev/null 2>&1; then
        lipo -info "${OUT_LIB}"
    fi
    echo "✓ ${OUT_LIB}"
    exit 0
fi

if ! command -v lipo >/dev/null 2>&1; then
    echo "error: lipo is required to create a universal macOS static library" >&2
    exit 1
fi

ARM64_LIB="${OUT_DIR}/libomni_layout_arm64.a"
X86_64_LIB="${OUT_DIR}/libomni_layout_x86_64.a"

build_one "aarch64-macos" "${ARM64_LIB}"
build_one "x86_64-macos" "${X86_64_LIB}"

echo "▸ lipo create  out=${OUT_LIB}"
lipo -create -output "${OUT_LIB}" "${ARM64_LIB}" "${X86_64_LIB}"
lipo -info "${OUT_LIB}"

echo "✓ ${OUT_LIB}"
