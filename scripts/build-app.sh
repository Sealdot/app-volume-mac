#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/volume-guard"
APP_DIR="$PROJECT_DIR/dist/VolumeGuard.app"
SIGNING_IDENTITY="${VOLUME_GUARD_CODESIGN_IDENTITY:--}"
CORE_SOURCES=("$PROJECT_DIR"/Sources/VolumeGuardCore/*.swift)
APP_SOURCES=("$PROJECT_DIR"/Sources/VolumeGuard/*.swift)

rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -O \
  -emit-library \
  -static \
  -emit-module \
  -module-name VolumeGuardCore \
  "${CORE_SOURCES[@]}" \
  -emit-module-path "$BUILD_DIR/VolumeGuardCore.swiftmodule" \
  -o "$BUILD_DIR/libVolumeGuardCore.a"

swiftc \
  -O \
  "${APP_SOURCES[@]}" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lVolumeGuardCore \
  -framework AppKit \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework UserNotifications \
  -o "$APP_DIR/Contents/MacOS/VolumeGuard"

cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

if command -v codesign >/dev/null 2>&1; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign \
      --force \
      --options runtime \
      --timestamp=none \
      --sign "$SIGNING_IDENTITY" \
      "$APP_DIR" >/dev/null
  else
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$SIGNING_IDENTITY" \
      "$APP_DIR" >/dev/null
  fi
fi

echo "构建完成：$APP_DIR"
