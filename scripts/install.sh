#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/VolumeGuard.app"
DESTINATION_APP="/Applications/VolumeGuard.app"

"$SCRIPT_DIR/build-app.sh"
ditto "$SOURCE_APP" "$DESTINATION_APP"
open "$DESTINATION_APP"

echo "已安装并打开：$DESTINATION_APP"
