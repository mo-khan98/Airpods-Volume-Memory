#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/airpods-volume-tests.XXXXXX")"
TEST_BINARY="$TEST_BUILD_DIR/VolumeMemoryControllerTests"

trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

swiftc \
  -swift-version 5 \
  -framework CoreAudio \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/AudioDevice.swift" \
  "$ROOT_DIR/Sources/AirpodVolumeMacApp/VolumeMemoryController.swift" \
  "$ROOT_DIR/Tests/VolumeMemoryControllerTests.swift"

"$TEST_BINARY"
