#!/usr/bin/env bash
set -euo pipefail

# Regenerates Resources/AppIcon.icns. Pass a folder to also write notification previews.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/airpods-volume-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -framework AppKit \
  -o "$WORK_DIR/make-icon" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/VolumeGauge.swift" \
  "$ROOT_DIR/scripts/make-icon.swift"

if [[ $# -ge 1 ]]; then
  "$WORK_DIR/make-icon" "$WORK_DIR/AppIcon.iconset" --previews "$1"
else
  "$WORK_DIR/make-icon" "$WORK_DIR/AppIcon.iconset"
fi
iconutil -c icns "$WORK_DIR/AppIcon.iconset" -o "$ROOT_DIR/Resources/AppIcon.icns"
echo "Wrote $ROOT_DIR/Resources/AppIcon.icns"
