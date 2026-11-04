#!/bin/sh
# Update an existing installation in place; do not use Flutter's uninstall flow.
set -eu
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <iPhone-device-id>\n' "$0" >&2
  exit 2
fi
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$APP_DIR"
flutter build ios --release
xcrun devicectl device install app --device "$1" "$APP_DIR/build/ios/iphoneos/Runner.app"
