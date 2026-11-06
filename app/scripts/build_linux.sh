#!/bin/sh
# Builds Yomi for Linux x86_64 and packages it as one AppImage that runs on any recent
# distro. Runs on Linux (the release workflow's Ubuntu job). Needs Flutter, Go, and:
#   clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev libsecret-1-dev
#   build_linux.sh --build-name=1.2.0
set -eu
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RELEASE_DIR="$APP_DIR/../release"
BRIDGE_DIR="$APP_DIR/../tailscale_bridge"
TOOLS="$APP_DIR/build/linux-tools"
LINUXDEPLOY_URL=https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
APPIMAGETOOL_URL=https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage

"$BRIDGE_DIR/build.sh" linux
cd "$APP_DIR"
flutter pub get
flutter build linux --release "$@"
BUNDLE="$APP_DIR/build/linux/x64/release/bundle"

APPDIR="$APP_DIR/build/linux/Yomi.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/512x512/apps"
# The Flutter executable looks for data/ and lib/ beside itself.
cp -R "$BUNDLE/." "$APPDIR/usr/bin/"
cp "$APP_DIR/linux/packaging/yomi.desktop" "$APPDIR/usr/share/applications/"
cp "$APP_DIR/assets/icon/icon.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/yomi.png"

mkdir -p "$TOOLS"
[ -x "$TOOLS/linuxdeploy" ] || { curl -fsSL -o "$TOOLS/linuxdeploy" "$LINUXDEPLOY_URL"; chmod +x "$TOOLS/linuxdeploy"; }
[ -x "$TOOLS/appimagetool" ] || { curl -fsSL -o "$TOOLS/appimagetool" "$APPIMAGETOOL_URL"; chmod +x "$TOOLS/appimagetool"; }

# Copies what the app and its plugins link against (libmpv and friends) into the
# AppImage, leaving out the libraries every desktop has (glibc, GTK).
LIBRARY_ARGS=""
for library in "$APPDIR"/usr/bin/lib/*.so; do
  LIBRARY_ARGS="$LIBRARY_ARGS --library $library"
done
# shellcheck disable=SC2086
APPIMAGE_EXTRACT_AND_RUN=1 "$TOOLS/linuxdeploy" --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/yomi" $LIBRARY_ARGS \
  --desktop-file "$APPDIR/usr/share/applications/yomi.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/512x512/apps/yomi.png"

mkdir -p "$RELEASE_DIR"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$TOOLS/appimagetool" "$APPDIR" \
  "$RELEASE_DIR/Yomi-linux-x86_64.AppImage"
printf 'Linux app: %s/Yomi-linux-x86_64.AppImage\n' "$RELEASE_DIR"
