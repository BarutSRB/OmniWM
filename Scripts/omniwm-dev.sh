#!/usr/bin/env bash
# Maintain a side-by-side development copy of OmniWM.
#
#   omniwm-dev.sh install        build the current tree as "OmniWM Dev.app",
#                                install it to /Applications, and switch to it
#   omniwm-dev.sh use dev        quit the release copy, launch the dev copy
#   omniwm-dev.sh use release    quit the dev copy, launch the release copy
#
# The dev copy has bundle id com.barut.OmniWM.dev, so macOS keeps its
# Accessibility and Input Monitoring grants separate from the release copy.
# Grants survive rebuilds only when the signature is stable: create a
# self-signed "Code Signing" certificate named "OmniWM Dev" in Keychain Access
# and this script will use it. Without one the build is ad-hoc signed and
# macOS asks for the grants again after every rebuild.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_APP_NAME="${OMNIWM_DEV_APP_NAME:-OmniWM Dev}"
DEV_BUNDLE_ID="${OMNIWM_DEV_BUNDLE_ID:-com.barut.OmniWM.dev}"
DEV_IDENTITY="${OMNIWM_SIGNING_IDENTITY:-OmniWM Dev}"
INSTALL_DIR="${OMNIWM_DEV_INSTALL_DIR:-/Applications}"
RELEASE_APP="${OMNIWM_RELEASE_APP:-/Applications/OmniWM.app}"
RELEASE_BUNDLE_ID="com.barut.OmniWM"
DEV_APP="$INSTALL_DIR/$DEV_APP_NAME.app"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 64
}

quit_app() {
  local bundle_id="$1"
  if ! pgrep -qx OmniWM; then
    return 0
  fi
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    if ! osascript -e "tell application \"System Events\" to (bundle identifier of processes) contains \"$bundle_id\"" 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 0.25
  done
  echo "omniwm-dev: $bundle_id did not quit cleanly, killing it" >&2
  pkill -f "/Contents/MacOS/OmniWM$" || true
}

wait_for_no_omniwm() {
  # The launch conflict checker blocks a second OmniWM process, so make sure
  # the previous copy is gone before opening the next one.
  for _ in $(seq 1 40); do
    pgrep -qx OmniWM || return 0
    sleep 0.25
  done
  echo "omniwm-dev: an OmniWM process is still running; the new copy will wait for it" >&2
}

install_dev() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$DEV_IDENTITY\""; then
    echo "omniwm-dev: signing with \"$DEV_IDENTITY\" (privacy grants will survive rebuilds)"
  else
    echo "omniwm-dev: no \"$DEV_IDENTITY\" certificate found; ad-hoc signing (grants reset on every rebuild)" >&2
  fi

  OMNIWM_APP_NAME="$DEV_APP_NAME" \
  OMNIWM_BUNDLE_ID="$DEV_BUNDLE_ID" \
  OMNIWM_SIGNING_IDENTITY="$DEV_IDENTITY" \
    "$ROOT_DIR/Scripts/package-app.sh" debug dev

  quit_app "$RELEASE_BUNDLE_ID"
  quit_app "$DEV_BUNDLE_ID"
  wait_for_no_omniwm

  rm -rf "$DEV_APP"
  ditto "$ROOT_DIR/dist/$DEV_APP_NAME.app" "$DEV_APP"
  echo "omniwm-dev: installed $DEV_APP"
  open "$DEV_APP"
}

use_copy() {
  case "${1:-}" in
    dev)
      [ -d "$DEV_APP" ] || { echo "omniwm-dev: $DEV_APP is missing; run 'make dev-install' first" >&2; exit 1; }
      quit_app "$RELEASE_BUNDLE_ID"
      wait_for_no_omniwm
      open "$DEV_APP"
      ;;
    release)
      [ -d "$RELEASE_APP" ] || { echo "omniwm-dev: $RELEASE_APP is missing" >&2; exit 1; }
      quit_app "$DEV_BUNDLE_ID"
      wait_for_no_omniwm
      open "$RELEASE_APP"
      ;;
    *)
      usage
      ;;
  esac
}

case "${1:-}" in
  install) install_dev ;;
  use) use_copy "${2:-}" ;;
  *) usage ;;
esac
