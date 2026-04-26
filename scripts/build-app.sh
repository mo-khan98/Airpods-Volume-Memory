#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AirpodVolumeMacApp"
DISPLAY_NAME="AirPods Volume"
CONFIGURATION="${CONFIGURATION:-release}"

cd "$ROOT_DIR"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This app is intended for Apple Silicon Macs. Current architecture: $(uname -m)" >&2
  exit 1
fi

swift build -c "$CONFIGURATION" --arch arm64
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"

APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

echo "Built $DISPLAY_NAME at:"
echo "$APP_BUNDLE"
echo
echo "Run it with:"
echo "open \"$APP_BUNDLE\""
