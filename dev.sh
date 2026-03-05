#!/usr/bin/env bash
# dev.sh — reliable local build/run flow for Zig + Swift.
#
# Usage:
#   ./dev.sh                    # clean + build Zig + build Swift + run via swift run
#   ./dev.sh --build-only       # clean + build Zig + build Swift (no run)
#   ./dev.sh --app              # clean + package debug unsigned OmniWM.app
#   ./dev.sh --app --run        # clean + package debug unsigned OmniWM.app + open app
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./dev.sh
  ./dev.sh --build-only
  ./dev.sh --app
  ./dev.sh --app --run
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_MODE=false
RUN_FLAG=false
BUILD_ONLY=false

for arg in "$@"; do
    case "${arg}" in
        --app)
            APP_MODE=true
            ;;
        --run)
            RUN_FLAG=true
            ;;
        --build-only)
            BUILD_ONLY=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "${APP_MODE}" == "false" && "${RUN_FLAG}" == "true" ]]; then
    echo "--run is only valid with --app (default mode already runs via swift run)." >&2
    usage >&2
    exit 1
fi

if [[ "${APP_MODE}" == "true" && "${BUILD_ONLY}" == "true" ]]; then
    echo "--build-only cannot be combined with --app." >&2
    usage >&2
    exit 1
fi

echo "==> Cleaning SwiftPM and previous artifacts"
rm -rf .build dist/OmniWM.app
swift package clean

if [[ "${APP_MODE}" == "true" ]]; then
    echo "==> Building Zig + Swift and packaging OmniWM.app (debug, unsigned)"
    ./Scripts/package-app.sh debug false

    APP_BIN="dist/OmniWM.app/Contents/MacOS/OmniWM"
    ZIG_LIB=".build/zig/libomni_layout.a"

    if [[ -f "${ZIG_LIB}" ]]; then
        echo "==> Zig archive timestamp:"
        stat -f "%Sm %N" "${ZIG_LIB}"
        if rg -q "omni_niri_ctx_apply_txn|omni_niri_ctx_export_delta" < <(nm "${ZIG_LIB}" 2>/dev/null || true); then
            echo "==> Zig archive check: txn symbols found"
        else
            echo "==> Zig archive check: ERROR missing txn symbols" >&2
            exit 1
        fi
    fi
    if [[ -x "${APP_BIN}" ]]; then
        echo "==> App binary timestamp:"
        stat -f "%Sm %N" "${APP_BIN}"
        if rg -q "omni_niri_ctx_apply_txn|omni_niri_ctx_export_delta" < <(nm "${APP_BIN}" 2>/dev/null || true); then
            echo "==> App binary symbol check: txn symbols visible"
        else
            echo "==> App binary symbol check: symbol not visible (likely linker-internalized/stripped)"
        fi
    fi

    echo "==> Accessibility reminder:"
    echo "   If hotkeys are inactive, grant Accessibility to OmniWM.app in System Settings."
    echo "   Open directly: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"

    if [[ "${RUN_FLAG}" == "true" ]]; then
        echo "==> Opening dist/OmniWM.app"
        open dist/OmniWM.app
    else
        echo "==> Built dist/OmniWM.app"
    fi
    exit 0
fi

echo "==> Building Zig static library"
./build-zig.sh

echo "==> Building Swift"
swift build

if [[ "${BUILD_ONLY}" == "true" ]]; then
    echo "==> Build complete (no run)"
else
    echo "==> Running via swift run"
    swift run
fi
