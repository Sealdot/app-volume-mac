#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_EXECUTABLE="$PROJECT_DIR/dist/VolumeGuard.app/Contents/MacOS/VolumeGuard"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi

"$APP_EXECUTABLE" >/tmp/volume-guard-performance.log 2>&1 &
APP_PID=$!
cleanup() {
  kill "$APP_PID" >/dev/null 2>&1 || true
  wait "$APP_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 5
if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
  echo "性能检查失败：App 未保持运行"
  exit 1
fi

METRICS="$(ps -p "$APP_PID" -o rss=,%cpu= | awk '{$1=$1; print}')"
RSS_KB="$(echo "$METRICS" | awk '{print $1}')"
CPU_PERCENT="$(echo "$METRICS" | awk '{print $2}')"

echo "VolumeGuard PID: $APP_PID"
echo "常驻内存 RSS: $((RSS_KB / 1024)) MB"
echo "CPU: $CPU_PERCENT%"

if (( RSS_KB > 81920 )); then
  echo "性能检查失败：RSS 超过 80 MB"
  exit 1
fi
