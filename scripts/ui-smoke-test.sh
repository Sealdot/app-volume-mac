#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/dist/VolumeGuard.app"
TEMP_DIR="$(mktemp -d)"
GENERAL_SUITE="com.volumeguard.ui.general.$$.test"
RULES_SUITE="com.volumeguard.ui.rules.$$.test"
EMPTY_RULES_SUITE="com.volumeguard.ui.empty-rules.$$.test"
REMOVAL_SUITE="com.volumeguard.ui.removal.$$.test"

cleanup() {
  defaults delete "$GENERAL_SUITE" >/dev/null 2>&1 || true
  defaults delete "$RULES_SUITE" >/dev/null 2>&1 || true
  defaults delete "$EMPTY_RULES_SUITE" >/dev/null 2>&1 || true
  defaults delete "$REMOVAL_SUITE" >/dev/null 2>&1 || true
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
EMPTY_RULES_SNAPSHOT="$TEMP_DIR/empty-rules.png"

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
check_dimensions "$RULES_SNAPSHOT" 520 430

open -n "$APP_BUNDLE" --args \
  "--test-suite=$EMPTY_RULES_SUITE" \
  --snapshot-pane=rules \
  "--snapshot-settings=$EMPTY_RULES_SNAPSHOT"
wait_for_snapshot "$EMPTY_RULES_SNAPSHOT"
check_dimensions "$EMPTY_RULES_SNAPSHOT" 520 430

general_dimensions="$(sips -g pixelWidth -g pixelHeight "$GENERAL_SNAPSHOT" | awk '/pixelWidth/ {width=$2} /pixelHeight/ {height=$2} END {print width "x" height}')"
rules_dimensions="$(sips -g pixelWidth -g pixelHeight "$RULES_SNAPSHOT" | awk '/pixelWidth/ {width=$2} /pixelHeight/ {height=$2} END {print width "x" height}')"
empty_rules_dimensions="$(sips -g pixelWidth -g pixelHeight "$EMPTY_RULES_SNAPSHOT" | awk '/pixelWidth/ {width=$2} /pixelHeight/ {height=$2} END {print width "x" height}')"
if [[ "$general_dimensions" != "$rules_dimensions" || "$general_dimensions" != "$empty_rules_dimensions" ]]; then
  echo "UI 测试失败：通用页 ${general_dimensions}、规则页 ${rules_dimensions}、空规则页 ${empty_rules_dimensions} 尺寸不一致"
  exit 1
fi
echo "✓ 所有 pane 尺寸一致：$general_dimensions"

echo "设置窗口截图测试通过"

REMOVAL_RESULT="$TEMP_DIR/removal-result.txt"
open -n "$APP_BUNDLE" --args \
  "--test-suite=$REMOVAL_SUITE" \
  --ui-fixture \
  "--test-remove-result=$REMOVAL_RESULT"
wait_for_snapshot "$REMOVAL_RESULT"
if [[ "$(tr -d '\n' < "$REMOVAL_RESULT")" != "pass" ]]; then
  echo "UI 测试失败：移除后从状态栏入口重进时规则被恢复"
  exit 1
fi
echo "✓ 移除后从状态栏入口重进，规则未恢复"
echo "设置窗口 UI 烟雾测试通过"
