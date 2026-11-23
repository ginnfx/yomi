#!/bin/sh
# Build an unsigned IPA for signing/sideloading; no Apple credentials in CI.
# Usage: scripts/build_ios.sh 1.2.3
set -eu
VERSION=${1:-}
case "$VERSION" in
  *[!0-9.]* | "" ) echo "Usage: $0 <major.minor.patch>" >&2; exit 2 ;;
esac
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RELEASE_DIR="$APP_DIR/../release"
cd "$APP_DIR"
flutter pub get
flutter build ios --release --no-codesign --build-name="$VERSION"
# The device .app is packaged as Payload/Runner.app, ready for a signing tool.
STAGE=$(mktemp -d "$APP_DIR/build/ios/unsigned-ipa.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Payload" "$RELEASE_DIR"
ditto --norsrc --noextattr "$APP_DIR/build/ios/iphoneos/Runner.app" "$STAGE/Payload/Runner.app"
# Incremental builds can retain a developer profile/signature from an earlier
# signed build. Never include that profile or its registered device IDs in CI assets.
find "$STAGE/Payload" -name embedded.mobileprovision -type f -delete
find "$STAGE/Payload" -depth -type d \( -name '*.app' -o -name '*.framework' \) -exec sh -c '
  set -e
  for bundle do
    if codesign -d "$bundle" >/dev/null 2>&1; then
      codesign --remove-signature "$bundle"
    fi
  done
' sh {} +
find "$STAGE/Payload" -depth -type d -name _CodeSignature -exec rm -rf {} +
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent Payload "$RELEASE_DIR/Yomi-iOS-unsigned.ipa")
(cd "$RELEASE_DIR" && shasum -a 256 Yomi-iOS-unsigned.ipa > Yomi-iOS-unsigned.ipa.sha256)
printf 'Unsigned iOS IPA: %s/Yomi-iOS-unsigned.ipa\n' "$RELEASE_DIR"
