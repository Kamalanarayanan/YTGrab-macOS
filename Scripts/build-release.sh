#!/bin/bash
# Builds a universal (Apple silicon + Intel) Release of YTGrab and packages
# it as a DMG in build/.
#
#   ./Scripts/build-release.sh
#
# Signing: ad-hoc by default. Set SIGN_IDENTITY to a "Developer ID
# Application: …" identity to sign for distribution (then notarize the DMG
# with `xcrun notarytool submit build/YTGrab-*.dmg --wait`).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
IDENTITY="${SIGN_IDENTITY:--}"

"$ROOT/Scripts/fetch-tools.sh"

xcodebuild \
  -project "$ROOT/YTGrab.xcodeproj" \
  -scheme YTGrab \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  build

APP="$DERIVED/Build/Products/Release/YTGrab.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo
echo "App binary:  $(lipo -archs "$APP/Contents/MacOS/YTGrab")"
for tool in yt-dlp ffmpeg ffprobe deno; do
  echo "$tool: $(lipo -archs "$APP/Contents/Resources/Tools/$tool")"
done
codesign --verify --deep --strict "$APP"

"$ROOT/Scripts/make-dmg.sh" "$APP" "$BUILD/YTGrab-$VERSION-Universal.dmg"
