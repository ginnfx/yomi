#!/bin/sh
# Puts the official yt-dlp inside a built Yomi.app. The Mac app is sandboxed, and a
# sandboxed app may only run programs from its own bundle, signed to inherit the
# sandbox. The one-folder build is used because the one-file build unpacks itself
# with semaphores the sandbox forbids. It lives in Resources because it brings data
# files that strict signature checks reject in Helpers. Re-sign the outer app afterwards.
#   bundle_ytdlp_macos.sh path/to/Yomi.app
set -eu
APP_BUNDLE=${1:?usage: bundle_ytdlp_macos.sh path/to/Yomi.app}
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RELEASES=https://github.com/yt-dlp/yt-dlp/releases/latest/download
ASSET=yt-dlp_macos.zip
HELPER_DIR="$APP_BUNDLE/Contents/Resources/yt-dlp"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl --fail --silent --show-error --location -o "$WORK/$ASSET" "$RELEASES/$ASSET"
curl --fail --silent --show-error --location -o "$WORK/SHA2-256SUMS" "$RELEASES/SHA2-256SUMS"
EXPECTED=$(awk -v name="$ASSET" '$2 == name { print $1 }' "$WORK/SHA2-256SUMS")
ACTUAL=$(shasum -a 256 "$WORK/$ASSET" | awk '{ print $1 }')
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "$ASSET checksum mismatch (expected '$EXPECTED', got '$ACTUAL')" >&2
  exit 1
fi

rm -rf "$HELPER_DIR"
mkdir -p "$HELPER_DIR"
ditto -x -k "$WORK/$ASSET" "$HELPER_DIR"
# Every library inside is signed plainly; the program itself inherits the sandbox.
find "$HELPER_DIR/_internal" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' \) \
  -exec codesign --force --sign - --timestamp=none {} \; 2>/dev/null
codesign --force --sign - --timestamp=none \
  --entitlements "$APP_DIR/macos/Runner/Helper.entitlements" \
  "$HELPER_DIR/yt-dlp_macos" 2>/dev/null
# It inherits the app sandbox, so it only runs when the app starts it.
echo "Bundled $ASSET into $APP_BUNDLE"
