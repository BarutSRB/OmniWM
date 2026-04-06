#!/bin/sh

omniwm_fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

omniwm_require_file() {
  [ -f "$1" ] || omniwm_fail "missing file: $1"
}

omniwm_require_command() {
  command -v "$1" >/dev/null 2>&1 || omniwm_fail "$1 is required"
}

omniwm_load_build_metadata() {
  if [ "$#" -gt 1 ]; then
    omniwm_fail "usage: omniwm_load_build_metadata [root_dir]"
  fi

  if [ "$#" -eq 1 ]; then
    OMNIWM_ROOT_DIR=$1
  elif [ -z "${OMNIWM_ROOT_DIR:-}" ]; then
    omniwm_fail "OMNIWM_ROOT_DIR must be set when omniwm_load_build_metadata is called without an argument"
  fi

  OMNIWM_BUILD_METADATA_FILE=${OMNIWM_BUILD_METADATA_FILE:-"$OMNIWM_ROOT_DIR/Scripts/build-metadata.env"}
  omniwm_require_file "$OMNIWM_BUILD_METADATA_FILE"

  # shellcheck disable=SC1090
  . "$OMNIWM_BUILD_METADATA_FILE"

  [ -n "${OMNIWM_MACOS_DEPLOYMENT_TARGET:-}" ] || omniwm_fail "OMNIWM_MACOS_DEPLOYMENT_TARGET is missing from $OMNIWM_BUILD_METADATA_FILE"
  [ -n "${OMNIWM_REQUIRED_ZIG_VERSION:-}" ] || omniwm_fail "OMNIWM_REQUIRED_ZIG_VERSION is missing from $OMNIWM_BUILD_METADATA_FILE"
  [ -n "${OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH:-}" ] || omniwm_fail "OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH is missing from $OMNIWM_BUILD_METADATA_FILE"
  [ -n "${OMNIWM_GHOSTTY_ARCHIVE_SHA256:-}" ] || omniwm_fail "OMNIWM_GHOSTTY_ARCHIVE_SHA256 is missing from $OMNIWM_BUILD_METADATA_FILE"

  OMNIWM_GHOSTTY_ARCHIVE_PATH=$OMNIWM_ROOT_DIR/$OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH
  OMNIWM_GHOSTTY_ARCHIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$OMNIWM_GHOSTTY_ARCHIVE_PATH")" && pwd)
}

omniwm_require_swiftpm_config() {
  case "$1" in
    debug|release)
      ;;
    *)
      omniwm_fail "unsupported SwiftPM configuration: $1 (use debug or release)"
      ;;
  esac
}

omniwm_require_zig_build_config() {
  case "$1" in
    debug|release|release-safe|release-small)
      ;;
    *)
      omniwm_fail "unsupported Zig kernel build configuration: $1 (use debug, release, release-safe, or release-small)"
      ;;
  esac
}

omniwm_zig_optimize_for_config() {
  case "$1" in
    debug)
      printf '%s\n' "Debug"
      ;;
    release)
      printf '%s\n' "ReleaseFast"
      ;;
    release-safe)
      printf '%s\n' "ReleaseSafe"
      ;;
    release-small)
      printf '%s\n' "ReleaseSmall"
      ;;
    *)
      omniwm_fail "cannot map unsupported Zig kernel build configuration: $1"
      ;;
  esac
}

omniwm_zig_target_for_arch() {
  case "$1" in
    arm64)
      printf 'aarch64-macos.%s\n' "$OMNIWM_MACOS_DEPLOYMENT_TARGET"
      ;;
    x86_64)
      printf 'x86_64-macos.%s\n' "$OMNIWM_MACOS_DEPLOYMENT_TARGET"
      ;;
    *)
      omniwm_fail "unsupported architecture: $1"
      ;;
  esac
}

omniwm_actual_ghostty_archive_sha256() {
  omniwm_require_command shasum
  shasum -a 256 "$OMNIWM_GHOSTTY_ARCHIVE_PATH" | awk '{print $1}'
}

omniwm_verify_ghostty_archive() {
  omniwm_require_command lipo
  omniwm_require_file "$OMNIWM_GHOSTTY_ARCHIVE_PATH"

  if ! lipo "$OMNIWM_GHOSTTY_ARCHIVE_PATH" -verify_arch arm64 x86_64 >/dev/null 2>&1; then
    printf '%s\n' "Ghostty archive is not universal: $OMNIWM_GHOSTTY_ARCHIVE_PATH" >&2
    lipo -info "$OMNIWM_GHOSTTY_ARCHIVE_PATH" >&2 || true
    omniwm_fail "rebuild or recopy Ghostty so libghostty.a includes both arm64 and x86_64 before building OmniWM"
  fi

  OMNIWM_ACTUAL_GHOSTTY_ARCHIVE_SHA256=$(omniwm_actual_ghostty_archive_sha256)
  if [ "$OMNIWM_ACTUAL_GHOSTTY_ARCHIVE_SHA256" != "$OMNIWM_GHOSTTY_ARCHIVE_SHA256" ]; then
    printf '%s\n' "Ghostty archive digest mismatch for $OMNIWM_GHOSTTY_ARCHIVE_PATH" >&2
    printf '%s\n' "expected: $OMNIWM_GHOSTTY_ARCHIVE_SHA256" >&2
    printf '%s\n' "actual:   $OMNIWM_ACTUAL_GHOSTTY_ARCHIVE_SHA256" >&2
    omniwm_fail "update Scripts/build-metadata.env only after verifying the intended Ghostty archive"
  fi
}

omniwm_require_zig_version() {
  omniwm_require_command zig
  OMNIWM_ACTUAL_ZIG_VERSION=$(zig version)
  if [ "$OMNIWM_ACTUAL_ZIG_VERSION" != "$OMNIWM_REQUIRED_ZIG_VERSION" ]; then
    printf '%s\n' "Zig version mismatch" >&2
    printf '%s\n' "expected: $OMNIWM_REQUIRED_ZIG_VERSION" >&2
    printf '%s\n' "actual:   $OMNIWM_ACTUAL_ZIG_VERSION" >&2
    omniwm_fail "install the pinned Zig toolchain before building OmniWM"
  fi
}

omniwm_setup_ghostty_library_path() {
  if [ -n "${LIBRARY_PATH:-}" ]; then
    LIBRARY_PATH=$OMNIWM_GHOSTTY_ARCHIVE_DIR:$LIBRARY_PATH
  else
    LIBRARY_PATH=$OMNIWM_GHOSTTY_ARCHIVE_DIR
  fi
  export LIBRARY_PATH
}

omniwm_require_build_inputs() {
  omniwm_require_file "$OMNIWM_ROOT_DIR/Package.swift"
  omniwm_require_file "$OMNIWM_ROOT_DIR/Scripts/build-zig-kernels.sh"
  omniwm_require_file "$OMNIWM_ROOT_DIR/Scripts/build-preflight.sh"
  omniwm_require_file "$OMNIWM_BUILD_METADATA_FILE"
  omniwm_require_file "$OMNIWM_ROOT_DIR/Zig/omniwm_kernels/build.zig"
  omniwm_require_file "$OMNIWM_ROOT_DIR/Zig/omniwm_kernels/src/root.zig"
}

omniwm_require_release_inputs() {
  omniwm_require_build_inputs
  omniwm_require_file "$OMNIWM_ROOT_DIR/Info.plist"
  omniwm_require_file "$OMNIWM_ROOT_DIR/Scripts/package-app.sh"
}

omniwm_require_clean_git_tree() {
  omniwm_require_command git
  omniwm_git_status=$(git -C "$1" status --porcelain)
  if [ -n "$omniwm_git_status" ]; then
    printf '%s\n' "${2:-Repository} has uncommitted changes:" >&2
    printf '%s\n' "$omniwm_git_status" >&2
    omniwm_fail "commit, stash, or remove local changes before continuing"
  fi
}
