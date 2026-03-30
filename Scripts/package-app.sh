#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
SIGN_AND_NOTARIZE="${2:-true}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
BUILD_DIR="$ROOT_DIR/.build/apple/Products/$CONFIG_CAPITALIZED"
EXECUTABLE="$BUILD_DIR/OmniWM"
CLI_EXECUTABLE="$BUILD_DIR/omniwmctl"
APP_DIR="$ROOT_DIR/dist/OmniWM.app"
GHOSTTY_LIBRARY="$ROOT_DIR/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a"
GHOSTTY_LIBRARY_DIR="$(dirname "$GHOSTTY_LIBRARY")"

# Signing identity and notarization profile
SIGNING_IDENTITY="Developer ID Application: Oliver Nikolic (VF8LDJRGFM)"
NOTARIZE_PROFILE="OmniWM-Notarize"
ENTITLEMENTS="$ROOT_DIR/OmniWM.entitlements"

if [ ! -f "$GHOSTTY_LIBRARY" ]; then
  echo "Missing Ghostty archive at $GHOSTTY_LIBRARY" >&2
  echo "Build Ghostty and copy a universal libghostty.a into Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/ before packaging OmniWM." >&2
  exit 1
fi

if ! lipo "$GHOSTTY_LIBRARY" -verify_arch arm64 x86_64 >/dev/null 2>&1; then
  echo "Ghostty archive is not universal: $GHOSTTY_LIBRARY" >&2
  lipo -info "$GHOSTTY_LIBRARY" >&2 || true
  echo "Rebuild or recopy Ghostty so libghostty.a includes both arm64 and x86_64 before packaging OmniWM." >&2
  exit 1
fi

echo "Building OmniWM universal binary ($CONFIG)..."
LIBRARY_PATH="$GHOSTTY_LIBRARY_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}" swift build -c "$CONFIG" --arch arm64 --arch x86_64

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
