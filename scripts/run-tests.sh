#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/airpods-volume-tests.XXXXXX")"
TEST_BINARY="$TEST_BUILD_DIR/VolumeMemoryControllerTests"

trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

swiftc \
  -swift-version 5 \
  -framework IOBluetooth \
  -framework CoreAudio \
  -framework UserNotifications \
  -framework AppKit \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/AirPodsHandoffMonitor.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/AirPodsBluetooth.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/AudioDevice.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/VolumeMemoryController.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/AppPreferences.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/VolumeGauge.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/MenuStatusText.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/PlaybackStallDetector.swift" \
  "$ROOT_DIR/Tests/VolumeMemoryControllerTests.swift"

"$TEST_BINARY"

STARTUP_TEST_BINARY="$TEST_BUILD_DIR/StartupTests"
swiftc \
  -swift-version 5 \
  -framework AppKit \
  -framework ServiceManagement \
  -o "$STARTUP_TEST_BINARY" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/SingleInstance.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/LoginItemController.swift" \
  "$ROOT_DIR/Tests/StartupTests.swift"

"$STARTUP_TEST_BINARY"
