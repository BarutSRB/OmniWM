#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/Scripts/build-common.sh"
omniwm_load_build_metadata "$ROOT_DIR"

CONFIG="${1:-release}"
SIGN_AND_NOTARIZE="${2:-true}"
"$ROOT_DIR/Scripts/build-preflight.sh" package "$CONFIG"

CONFIG_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
BUILD_DIR="$ROOT_DIR/.build/apple/Products/$CONFIG_CAPITALIZED"
EXECUTABLE="$BUILD_DIR/OmniWM"
CLI_EXECUTABLE="$BUILD_DIR/omniwmctl"
APP_DIR="$ROOT_DIR/dist/OmniWM.app"

# Signing identity and notarization profile
SIGNING_IDENTITY="Developer ID Application: Oliver Nikolic (VF8LDJRGFM)"
NOTARIZE_PROFILE="OmniWM-Notarize"
ENTITLEMENTS="$ROOT_DIR/OmniWM.entitlements"

echo "Building OmniWM universal binary ($CONFIG)..."
"$ROOT_DIR/Scripts/build-universal-products.sh" "$CONFIG"

echo "Verifying universal binary..."
lipo -info "$EXECUTABLE"
lipo -info "$CLI_EXECUTABLE"

echo "Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/OmniWM"
cp "$CLI_EXECUTABLE" "$APP_DIR/Contents/MacOS/omniwmctl"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$BUILD_DIR/OmniWM_OmniWM.bundle" "$APP_DIR/Contents/Resources/"

RESOURCE_BUNDLE_DIR="$APP_DIR/Contents/Resources/OmniWM_OmniWM.bundle"
# SwiftPM currently copies build-tool plugin outputs into the resource bundle,
# but the app only needs the processed image assets at runtime.
rm -rf "$RESOURCE_BUNDLE_DIR/cache" "$RESOURCE_BUNDLE_DIR/debug" "$RESOURCE_BUNDLE_DIR/release"
rm -rf "$RESOURCE_BUNDLE_DIR/zig-cache"
rm -f "$RESOURCE_BUNDLE_DIR/kernels-built.txt"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
  echo "Signing $APP_DIR with hardened runtime..."
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$APP_DIR/Contents/MacOS/omniwmctl"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" --timestamp "$APP_DIR/Contents/MacOS/OmniWM"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" --timestamp "$APP_DIR"

  echo "Verifying signature..."
  codesign --verify --verbose "$APP_DIR"

  echo "Creating ZIP for notarization..."
  ZIP_PATH="$ROOT_DIR/dist/OmniWM.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

  echo "Submitting for notarization (this may take a few minutes)..."
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_DIR"

  echo "Verifying notarization..."
  spctl --assess --verbose=2 "$APP_DIR"

  rm -f "$ZIP_PATH"
  echo "Done! $APP_DIR is signed and notarized."
else
  echo "Done. Open $APP_DIR to grant Accessibility permissions."
  echo "Note: App is not signed. Run with 'release true' to sign and notarize."
fi
