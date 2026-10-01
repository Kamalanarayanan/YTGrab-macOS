#!/bin/bash
# Downloads YTGrab's embedded tools for Apple silicon and Intel, verifies
# them, and combines each pair into a universal binary in YTGrab/Tools.
#
#   ./Scripts/fetch-tools.sh            # only if tools.lock changed
#   FORCE=1 ./Scripts/fetch-tools.sh    # always re-download
#   ALLOW_THIN=1 ./Scripts/fetch-tools.sh  # accept a missing Intel FFmpeg
#
# Xcode runs this automatically as the first build phase, so a fresh clone
# builds with nothing else to install. Downloads are cached in .tools-cache.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/Scripts/tools.lock"
OUT="$ROOT/YTGrab/Tools"
CACHE="${YTGRAB_TOOLS_CACHE:-$ROOT/.tools-cache}"
STAMP="$OUT/.stamp"

# shellcheck source=tools.lock
source "$LOCK"

LOCK_HASH="$(shasum -a 256 "$LOCK" "$0" | shasum -a 256 | cut -c1-64)"
TOOLS=(yt-dlp ffmpeg ffprobe deno)

all_present() {
  for tool in "${TOOLS[@]}"; do
    [ -x "$OUT/$tool" ] || return 1
  done
  [ -f "$OUT/versions.json" ] || return 1
}

if [ -z "${FORCE:-}" ] && all_present && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$LOCK_HASH" ]; then
  echo "Embedded tools are up to date."
  exit 0
fi

mkdir -p "$OUT" "$CACHE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MANIFEST="$WORK/README.txt"
{
  echo "YTGrab embedded tool manifest (universal: arm64 + x86_64)"
  echo "Generated $(date -u +%Y-%m-%d) by Scripts/fetch-tools.sh"
  echo
} > "$MANIFEST"

note() { echo "$*" >> "$MANIFEST"; }

sha() { shasum -a 256 "$1" | cut -c1-64; }

# fetch URL DEST [SHA256]
# Follows redirects, verifies the pinned hash, or the server's own .sha256
# when no hash is pinned. Prints the final URL.
fetch() {
  local url="$1" dest="$2" expected="${3:-}"
  local key cached effective
  key="$(echo "$url" | shasum -a 256 | cut -c1-16)-$(basename "$dest")"
  cached="$CACHE/$key"

  if [ -n "$expected" ] && [ -f "$cached" ] && [ "$(sha "$cached")" = "$expected" ]; then
    cp "$cached" "$dest"
    echo "$url"
    return 0
  fi

  effective="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -w '%{url_effective}' -o "$dest" "$url")" || return 1

  local actual
  actual="$(sha "$dest")"
  if [ -n "$expected" ]; then
    if [ "$actual" != "$expected" ]; then
      echo "Checksum mismatch for $url" >&2
      echo "  expected $expected" >&2
      echo "  got      $actual" >&2
      return 2
    fi
  else
    local published
    published="$(curl -fsSL --retry 2 "$effective.sha256" 2>/dev/null | grep -Eo '[0-9a-f]{64}' | head -1 || true)"
    if [ -n "$published" ]; then
      if [ "$published" != "$actual" ]; then
        echo "Checksum mismatch for $effective (published $published, got $actual)" >&2
        return 2
      fi
      echo "  verified against published SHA-256" >&2
    else
      echo "  warning: no checksum pinned or published for $effective" >&2
    fi
    echo "  SHA-256 $actual  (pin this in Scripts/tools.lock)" >&2
  fi
  cp "$dest" "$cached"
  echo "$effective"
}

# unpack ZIP NAME DEST: extract one executable from an archive.
unpack() {
  local zip="$1" name="$2" dest="$3" dir
  dir="$(mktemp -d "$WORK/unzip.XXXX")"
  /usr/bin/ditto -x -k "$zip" "$dir"
  local found
  found="$(find "$dir" -type f -name "$name" | head -1)"
  [ -n "$found" ] || { echo "No $name inside $zip" >&2; return 1; }
  mv "$found" "$dest"
  chmod 755 "$dest"
}

archs() { lipo -archs "$1" 2>/dev/null || echo "unknown"; }

# Re-sign only when the signature is missing or broken. Upstream signatures
# (Deno ships with a Developer ID) are better than a local ad-hoc one.
sign_if_needed() {
  if ! codesign --verify "$1" 2>/dev/null; then
    codesign --force --sign - --timestamp=none "$1"
  fi
}

# --- yt-dlp ------------------------------------------------------------------

echo "yt-dlp $YTDLP_VERSION"
url="$(fetch "$YTDLP_URL" "$WORK/yt-dlp" "$YTDLP_SHA256")"
chmod 755 "$WORK/yt-dlp"
note "yt-dlp $YTDLP_VERSION ($(archs "$WORK/yt-dlp"))"
note "  $url"
note "  SHA-256 $YTDLP_SHA256"
note

# --- Deno --------------------------------------------------------------------

echo "Deno $DENO_VERSION"
fetch "$DENO_ARM64_URL" "$WORK/deno-arm64.zip" "$DENO_ARM64_SHA256" >/dev/null
fetch "$DENO_X64_URL" "$WORK/deno-x64.zip" "$DENO_X64_SHA256" >/dev/null
unpack "$WORK/deno-arm64.zip" deno "$WORK/deno-arm64"
unpack "$WORK/deno-x64.zip" deno "$WORK/deno-x64"
lipo -create "$WORK/deno-arm64" "$WORK/deno-x64" -output "$WORK/deno"
note "Deno $DENO_VERSION ($(archs "$WORK/deno"))"
note "  $DENO_ARM64_URL"
note "  SHA-256 $DENO_ARM64_SHA256"
note "  $DENO_X64_URL"
note "  SHA-256 $DENO_X64_SHA256"
note

# --- FFmpeg / FFprobe ----------------------------------------------------------

# build_universal NAME ARM_URL ARM_SHA "X64_URLS" X64_SHA
build_universal() {
  local name="$1" arm_url="$2" arm_sha="$3" x64_urls="$4" x64_sha="$5"
  local effective

  echo "$name (Apple silicon)"
  effective="$(fetch "$arm_url" "$WORK/$name-arm64.zip" "$arm_sha")"
  unpack "$WORK/$name-arm64.zip" "$name" "$WORK/$name-arm64"
  note "$name arm64: $effective"
  note "  SHA-256 $(sha "$WORK/$name-arm64.zip") (archive)"

  echo "$name (Intel)"
  local got_x64=""
  for candidate in $x64_urls; do
    if effective="$(fetch "$candidate" "$WORK/$name-x64.zip" "$x64_sha")" \
       && unpack "$WORK/$name-x64.zip" "$name" "$WORK/$name-x64" \
       && [ "$(archs "$WORK/$name-x64")" = "x86_64" ]; then
      got_x64="yes"
      note "$name x86_64: $effective"
      note "  SHA-256 $(sha "$WORK/$name-x64.zip") (archive)"
      break
    fi
    echo "  $candidate unavailable, trying the next source" >&2
    rm -f "$WORK/$name-x64" "$WORK/$name-x64.zip"
  done

  if [ -n "$got_x64" ]; then
    lipo -create "$WORK/$name-arm64" "$WORK/$name-x64" -output "$WORK/$name"
  elif [ -n "${ALLOW_THIN:-}" ]; then
    echo "  warning: no Intel $name found; this build will not run on Intel Macs" >&2
    cp "$WORK/$name-arm64" "$WORK/$name"
  else
    echo "No Intel build of $name could be downloaded. Set ALLOW_THIN=1 to build Apple-silicon-only." >&2
    exit 1
  fi
  note
}

build_universal ffmpeg "$FFMPEG_ARM64_URL" "$FFMPEG_ARM64_SHA256" "$FFMPEG_X64_URLS" "$FFMPEG_X64_SHA256"
build_universal ffprobe "$FFPROBE_ARM64_URL" "$FFPROBE_ARM64_SHA256" "$FFPROBE_X64_URLS" "$FFPROBE_X64_SHA256"

# --- Sign, record, install -----------------------------------------------------------

for tool in "${TOOLS[@]}"; do
  chmod 755 "$WORK/$tool"
  xattr -c "$WORK/$tool" 2>/dev/null || true
  sign_if_needed "$WORK/$tool"
done

FFMPEG_VERSION="$("$WORK/ffmpeg" -version | head -1 | awk '{print $3}' | cut -d- -f1)"
note "FFmpeg build (native slice): $("$WORK/ffmpeg" -version | head -1)"
note
note "Architectures:"
for tool in "${TOOLS[@]}"; do
  note "  $tool: $(archs "$WORK/$tool")"
done
note
note "The upstream downloads were verified before extraction. Binaries whose"
note "signature did not survive packaging were re-signed ad-hoc. The app"
note "installs only this Mac's slice into Application Support."

cat > "$WORK/versions.json" <<JSON
{
  "yt-dlp": "$YTDLP_VERSION",
  "deno": "$DENO_VERSION",
  "ffmpeg": "$FFMPEG_VERSION"
}
JSON

for tool in "${TOOLS[@]}"; do
  mv -f "$WORK/$tool" "$OUT/$tool"
done
mv -f "$WORK/versions.json" "$OUT/versions.json"
mv -f "$MANIFEST" "$OUT/README.txt"
echo "$LOCK_HASH" > "$STAMP"

echo
cat "$OUT/README.txt"
