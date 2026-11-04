#!/bin/bash
# Builds the embedded Tailscale bridge the app links against. Output is not committed.
#   build.sh android | apple
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:$(go env GOPATH)/bin"
command -v gomobile >/dev/null || go install golang.org/x/mobile/cmd/gomobile@latest
# Same SDK the Flutter build uses, when nothing else says where it is.
if [ -z "${ANDROID_HOME:-}" ] && [ -f ../app/android/local.properties ]; then
  ANDROID_HOME=$(sed -n 's/^sdk\.dir=//p' ../app/android/local.properties)
  export ANDROID_HOME
fi
mkdir -p build
case "${1:-}" in
  android)
    gomobile bind -target=android/arm64,android/arm -androidapi 24 -ldflags='-s -w' -trimpath \
      -o build/tailscale_bridge.aar .
    ;;
  apple)
    rm -rf build/TailscaleBridge.xcframework
    gomobile bind -target=ios,iossimulator,macos -ldflags='-s -w' -trimpath \
      -o build/TailscaleBridge.xcframework .
    ;;
  *)
    echo "usage: build.sh android|apple" >&2
    exit 1
    ;;
esac
