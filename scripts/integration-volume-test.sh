#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_EXECUTABLE="$PROJECT_DIR/dist/VolumeGuard.app/Contents/MacOS/VolumeGuard"
TEST_SUITE="com.volumeguard.integration.$$.test"
ORIGINAL_VOLUME="$(osascript -e 'output volume of (get volume settings)')"
ORIGINAL_MUTED="$(osascript -e 'output muted of (get volume settings)')"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  osascript -e "set volume output volume $ORIGINAL_VOLUME" >/dev/null
  if [[ "$ORIGINAL_MUTED" == "true" ]]; then
    osascript -e 'set volume with output muted' >/dev/null
  else
    osascript -e 'set volume without output muted' >/dev/null
  fi
  defaults delete "$TEST_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi

# Keep the whole test muted so the temporary high scalar can never make sound.
osascript -e 'set volume with output muted' >/dev/null
osascript -e 'set volume output volume 82 with output muted' >/dev/null
VOLUME_GUARD_TEST_SUITE="$TEST_SUITE" "$APP_EXECUTABLE" --background >/tmp/volume-guard-integration.log 2>&1 &
APP_PID=$!
sleep 1

ACTUAL_VOLUME=82
for _ in {1..20}; do
  sleep 0.1
  ACTUAL_VOLUME="$(osascript -e 'output volume of (get volume settings)')"
  if (( ACTUAL_VOLUME <= 21 )); then
    break
  fi
done

ACTUAL_MUTED="$(osascript -e 'output muted of (get volume settings)')"
if (( ACTUAL_VOLUME > 21 )); then
  echo "集成测试失败：音量仍为 $ACTUAL_VOLUME%，未降到 20% 上限"
  exit 1
fi
if [[ "$ACTUAL_MUTED" != "true" ]]; then
  echo "集成测试失败：保护过程意外取消了静音"
  exit 1
fi

osascript -e 'set volume output volume 67 with output muted' >/dev/null
sleep 1
MANUAL_VOLUME="$(osascript -e 'output volume of (get volume settings)')"
if (( MANUAL_VOLUME < 60 )); then
  echo "集成测试失败：手动调到 67% 后被抢回到 $MANUAL_VOLUME%"
  exit 1
fi

echo "集成测试通过：启动时 82% 自动降至 $ACTUAL_VOLUME%，手动调到 67% 后保持为 $MANUAL_VOLUME%，且全程静音"
