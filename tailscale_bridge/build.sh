#!/bin/bash
# Builds the embedded Tailscale bridge the app links against. Output is not committed.
#   build.sh android | apple | linux
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:$(go env GOPATH)/bin"
# Tools at the version go.mod pins, because release builds run close to the signing key.
MOBILE_VERSION=$(go list -m -f '{{.Version}}' golang.org/x/mobile)
[ "${1:-}" = linux ] || command -v gomobile >/dev/null || go install "golang.org/x/mobile/cmd/gomobile@$MOBILE_VERSION"
[ "${1:-}" = linux ] || command -v gobind >/dev/null || go install "golang.org/x/mobile/cmd/gobind@$MOBILE_VERSION"
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
  linux)
    # Runs on Linux (the release workflow's Ubuntu job); needs a C compiler for cgo.
    CGO_ENABLED=1 go build -buildmode=c-shared -ldflags='-s -w' -trimpath \
      -o build/libtailscale_bridge.so ./cshared
    ;;
  *)
    echo "usage: build.sh android|apple|linux" >&2
    exit 1
    ;;
esac
