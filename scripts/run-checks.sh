#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/checks"
CORE_SOURCES=("$PROJECT_DIR"/Sources/VolumeGuardCore/*.swift)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

swiftc \
  -Onone \
  -emit-library \
  -static \
  -emit-module \
  -module-name VolumeGuardCore \
  "${CORE_SOURCES[@]}" \
  -emit-module-path "$BUILD_DIR/VolumeGuardCore.swiftmodule" \
  -o "$BUILD_DIR/libVolumeGuardCore.a"

swiftc \
  -Onone \
  "$PROJECT_DIR/Tests/VolumeGuardCoreChecks/main.swift" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lVolumeGuardCore \
  -o "$BUILD_DIR/VolumeGuardCoreChecks"

"$BUILD_DIR/VolumeGuardCoreChecks"
