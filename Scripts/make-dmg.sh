#!/bin/bash
# Packages an app into a drag-to-Applications DMG.
#
#   ./Scripts/make-dmg.sh path/to/YTGrab.app build/YTGrab.dmg

set -euo pipefail

APP="$1"
DMG="$2"
NAME="$(basename "$APP" .app)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$NAME.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -ov -format ULFO "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
