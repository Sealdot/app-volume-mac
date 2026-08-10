#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/dist/VolumeGuard.app"
TEMP_DIR="$(mktemp -d)"
GENERAL_SUITE="com.volumeguard.ui.general.$$.test"
RULES_SUITE="com.volumeguard.ui.rules.$$.test"

cleanup() {
  defaults delete "$GENERAL_SUITE" >/dev/null 2>&1 || true
  defaults delete "$RULES_SUITE" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/VolumeGuard" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi

wait_for_snapshot() {
  local path="$1"
  for _ in {1..40}; do
    [[ -f "$path" ]] && return 0
    sleep 0.2
  done
  echo "UI 测试失败：未生成 $path"
  return 1
}

check_dimensions() {
  local path="$1"
  local minimum_width="$2"
  local minimum_height="$3"
  local width
  local height
  width="$(sips -g pixelWidth "$path" | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$path" | awk '/pixelHeight/ {print $2}')"
  if (( width < minimum_width || height < minimum_height )); then
    echo "UI 测试失败：$path 尺寸为 ${width}x${height}"
    return 1
  fi
  echo "✓ $(basename "$path") ${width}x${height}"
}

GENERAL_SNAPSHOT="$TEMP_DIR/general.png"
RULES_SNAPSHOT="$TEMP_DIR/rules.png"

open -n "$APP_BUNDLE" --args \
  "--test-suite=$GENERAL_SUITE" \
  "--snapshot-settings=$GENERAL_SNAPSHOT"
wait_for_snapshot "$GENERAL_SNAPSHOT"
check_dimensions "$GENERAL_SNAPSHOT" 520 430

open -n "$APP_BUNDLE" --args \
  "--test-suite=$RULES_SUITE" \
  --ui-fixture \
  --snapshot-pane=rules \
  "--snapshot-settings=$RULES_SNAPSHOT"
wait_for_snapshot "$RULES_SNAPSHOT"
check_dimensions "$RULES_SNAPSHOT" 600 440

echo "设置窗口 UI 烟雾测试通过"
