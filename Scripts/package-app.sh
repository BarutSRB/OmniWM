#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
SIGN_AND_NOTARIZE="${2:-true}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/$CONFIG"
EXECUTABLE="$BUILD_DIR/OmniWM"
APP_DIR="$ROOT_DIR/dist/OmniWM.app"

# Signing identity and notarization profile
SIGNING_IDENTITY="Developer ID Application: Oliver Nikolic (VF8LDJRGFM)"
NOTARIZE_PROFILE="OmniWM-Notarize"
ENTITLEMENTS="$ROOT_DIR/OmniWM.entitlements"

echo "Building OmniWM ($CONFIG)..."
swift build -c "$CONFIG"

echo "Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/OmniWM"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
  echo "Signing $APP_DIR with hardened runtime..."
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
