#!/bin/sh
set -eu
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RELEASE_DIR="$APP_DIR/../release"
BRIDGE_DIR="$APP_DIR/../tailscale_bridge"
"$BRIDGE_DIR/build.sh" apple
cd "$APP_DIR"
flutter pub get
flutter build macos --release "$@"
# Incremental Flutter builds can update App.framework after Xcode signs the
# outer bundle. Refresh the local signatures before making distributable copies.
APP_BUNDLE="$APP_DIR/build/macos/Build/Products/Release/Yomi.app"
for framework in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
  codesign --force --sign - --timestamp=none "$framework"
done
codesign --force --sign - --timestamp=none \
  --entitlements "$APP_DIR/macos/Runner/Release.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
mkdir -p "$RELEASE_DIR"
ditto "$APP_DIR/build/macos/Build/Products/Release/Yomi.app" "$RELEASE_DIR/Yomi.app"
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DIR/Yomi.app" "$RELEASE_DIR/Yomi-macOS.zip"
printf 'Mac app: %s/Yomi.app\nArchive: %s/Yomi-macOS.zip\n' "$RELEASE_DIR" "$RELEASE_DIR"
