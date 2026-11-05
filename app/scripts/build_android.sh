#!/bin/sh
# Builds the signed release APK plus its checksum, ready to publish.
# Usage: scripts/build_android.sh 1.2.3
set -eu
VERSION=${1:-}
case "$VERSION" in
  *[!0-9.]* | "" ) echo "Usage: $0 <major.minor.patch>" >&2; exit 2 ;;
esac
IFS=. read -r MAJOR MINOR PATCH EXTRA <<VERSION_PARTS
$VERSION
VERSION_PARTS
if [ -z "${PATCH:-}" ] || [ -n "${EXTRA:-}" ] || [ "$MINOR" -ge 100 ] || [ "$PATCH" -ge 100 ]; then
  echo "Version must be major.minor.patch, with minor and patch below 100: $VERSION" >&2
  exit 2
fi
# Android only installs a higher version code, so derive it from the version.
BUILD_NUMBER=$((MAJOR * 10000 + MINOR * 100 + PATCH))

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BRIDGE_DIR="$APP_DIR/../tailscale_bridge"
[ -f "$BRIDGE_DIR/build/tailscale_bridge.aar" ] || "$BRIDGE_DIR/build.sh" android
RELEASE_DIR="$APP_DIR/../release"
APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
cd "$APP_DIR"
flutter pub get
flutter build apk --release --build-name="$VERSION" --build-number="$BUILD_NUMBER"

# Refuse to publish an APK that installed copies would reject as an update.
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$(sed -n 's/^sdk.dir=//p' "$APP_DIR/android/local.properties")}}
EXPECTED=$(tr -d '[:space:]' < "$APP_DIR/android/release-cert.sha256")
# The newest build tools on a machine can print nothing (seen on GitHub's runners), so try
# each, newest first, until one reports the certificate.
ACTUAL=""
for APKSIGNER in $(ls "$SDK"/build-tools/*/apksigner | sort -Vr); do
  OUTPUT=$("$APKSIGNER" verify --print-certs "$APK" 2>&1 || true)
  ACTUAL=$(printf '%s\n' "$OUTPUT" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1 | tr -d '[:space:]')
  [ -n "$ACTUAL" ] && break
  echo "No certificate from $APKSIGNER:" >&2
  printf '%s\n' "$OUTPUT" | head -n 5 >&2
done
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "APK is signed by the wrong key: $ACTUAL (expected $EXPECTED)" >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR"
cp "$APK" "$RELEASE_DIR/Yomi-android.apk"
(cd "$RELEASE_DIR" && shasum -a 256 Yomi-android.apk > Yomi-android.apk.sha256)
printf 'Built %s (code %s): %s/Yomi-android.apk\n' "$VERSION" "$BUILD_NUMBER" "$RELEASE_DIR"
