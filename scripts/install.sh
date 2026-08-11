#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/VolumeGuard.app"
DESTINATION_APP="/Applications/VolumeGuard.app"

"$SCRIPT_DIR/build-app.sh"

# Stop only this app before replacing it so Finder never keeps the old binary
# or icon alive. The freshly installed copy is opened immediately afterwards.
pkill -x VolumeGuard >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x VolumeGuard >/dev/null 2>&1 || break
  sleep 0.1
done

ditto "$SOURCE_APP" "$DESTINATION_APP"
touch "$DESTINATION_APP"
open "$DESTINATION_APP"

echo "已安装并打开：$DESTINATION_APP"
