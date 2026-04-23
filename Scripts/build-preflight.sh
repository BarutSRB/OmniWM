#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/build-common.sh"
omniwm_load_build_metadata "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: ./Scripts/build-preflight.sh <command> [args]

Commands:
  build [debug|release]              Validate build prerequisites for SwiftPM builds
  package [debug|release]            Validate packaging prerequisites
  release-check                      Validate pre-release packaging prerequisites
  clean-tree [repo] [label]          Fail if the given git repo has local changes
  print-ghostty-library-dir          Print the Ghostty library directory
  print-ghostty-archive-path         Print the pinned Ghostty archive path
  print-verified-ghostty-sha256      Verify and print the Ghostty archive digest
  print-required-zig-version         Print the pinned Zig version
  print-verified-zig-version         Verify and print the local Zig version
  print-macos-deployment-target      Print the pinned macOS deployment target
EOF
}

command_name=${1:-}

case "$command_name" in
  build)
    build_config=${2:-debug}
    omniwm_require_swiftpm_config "$build_config"
    omniwm_require_build_inputs
    omniwm_verify_ghostty_archive
    omniwm_require_zig_version
    ;;
  package)
    package_config=${2:-release}
    omniwm_require_swiftpm_config "$package_config"
    omniwm_require_release_inputs
    omniwm_verify_ghostty_archive
    omniwm_require_zig_version
    ;;
  release-check)
    omniwm_require_release_inputs
    omniwm_verify_ghostty_archive
    omniwm_require_zig_version
    ;;
  clean-tree)
    omniwm_require_clean_git_tree "${2:-$ROOT_DIR}" "${3:-Repository}"
    ;;
  print-ghostty-library-dir)
    printf '%s\n' "$OMNIWM_GHOSTTY_ARCHIVE_DIR"
    ;;
  print-ghostty-archive-path)
    printf '%s\n' "$OMNIWM_GHOSTTY_ARCHIVE_PATH"
    ;;
  print-verified-ghostty-sha256)
    omniwm_verify_ghostty_archive
    printf '%s\n' "$OMNIWM_ACTUAL_GHOSTTY_ARCHIVE_SHA256"
    ;;
  print-required-zig-version)
    printf '%s\n' "$OMNIWM_REQUIRED_ZIG_VERSION"
    ;;
  print-verified-zig-version)
    omniwm_require_zig_version
    printf '%s\n' "$OMNIWM_ACTUAL_ZIG_VERSION"
    ;;
  print-macos-deployment-target)
    printf '%s\n' "$OMNIWM_MACOS_DEPLOYMENT_TARGET"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
