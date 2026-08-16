#!/bin/bash
# Regenerates the app icon set from a single source image.
#
#   ./install-icon.sh ~/Desktop/ytgrab-logo.png
#
# Give it a square PNG, 1024x1024 or larger. Everything in
# Assets.xcassets/AppIcon.appiconset gets rebuilt. Rebuild in Xcode afterwards
# The separate CRIT studio mark used by About is intentionally unchanged.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$1"
ICONSET="$HERE/YTGrab/Assets.xcassets/AppIcon.appiconset"

if [ -z "$SOURCE" ]; then
  echo "Usage: ./install-icon.sh path/to/logo.png"
  exit 1
fi

if [ ! -f "$SOURCE" ]; then
  echo "Not found: $SOURCE"
  exit 1
fi

WIDTH=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/{print $2}')
HEIGHT=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/{print $2}')

if [ "$WIDTH" != "$HEIGHT" ]; then
  echo "Warning: $SOURCE is ${WIDTH}x${HEIGHT}, not square. macOS will squash it."
fi

if [ "$WIDTH" -lt 1024 ]; then
  echo "Warning: source is only ${WIDTH}px wide. 1024 or larger gives a clean 512@2x."
fi

mkdir -p "$ICONSET"
rm -f "$ICONSET"/*.png

# macOS wants exactly these ten. Anything else and the catalogue fails to
# compile with an unhelpful error.
for pair in "16 16x16 1x" "32 16x16 2x" "32 32x32 1x" "64 32x32 2x" \
            "128 128x128 1x" "256 128x128 2x" "256 256x256 1x" "512 256x256 2x" \
            "512 512x512 1x" "1024 512x512 2x"; do
  set -- $pair
  px=$1; label=$2; scale=$3
  suffix=""
  [ "$scale" = "2x" ] && suffix="@2x"
  sips -z "$px" "$px" "$SOURCE" --out "$ICONSET/icon_${label}${suffix}.png" >/dev/null
done

# Rewrite the manifest to match what was just produced.
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",      "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",   "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",      "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",   "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",    "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png", "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",    "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png", "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",    "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png", "scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

echo "Icon set rebuilt from $(basename "$SOURCE")"
echo "In Xcode: Product > Clean Build Folder, then Run."
echo
echo "The CRIT mark in About remains separate from the app icon."
