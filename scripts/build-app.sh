#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AirpodVolumeMacApp"
DISPLAY_NAME="AirPods Volume"
BUILD_CONFIGURATION="${AIRPODS_VOLUME_CONFIGURATION:-release}"
BUILD_ARCH="${AIRPODS_VOLUME_ARCH:-$(uname -m)}"

cd "$ROOT_DIR"

case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported build architecture: $BUILD_ARCH" >&2
    exit 1
    ;;
esac

bash "$ROOT_DIR/scripts/run-tests.sh"
swift build -c "$BUILD_CONFIGURATION" --arch "$BUILD_ARCH"
BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --arch "$BUILD_ARCH" --show-bin-path)"

APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_BUNDLE" >/dev/null
fi

echo "Built $DISPLAY_NAME at:"
echo "$APP_BUNDLE"
echo
echo "Run it with:"
echo "open \"$APP_BUNDLE\""
