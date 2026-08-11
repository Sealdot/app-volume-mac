#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/dist/VolumeGuard.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/VolumeGuard"

if [[ ! -x "$EXECUTABLE" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi

plutil -lint "$PROJECT_DIR/Resources/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)"
if [[ "$SIGNATURE_DETAILS" != *"runtime"* ]]; then
  echo "安全检查失败：App 未启用 Hardened Runtime"
  exit 1
fi

if rg -n 'URLSession|NWConnection|WKWebView|NSMicrophoneUsageDescription|NSAudioCaptureUsageDescription' \
  "$PROJECT_DIR/Sources" "$PROJECT_DIR/Resources" >/dev/null; then
  echo "安全检查失败：检测到未审阅的网络或音频采集能力"
  exit 1
fi

NON_SYSTEM_LIBRARIES="$(otool -L "$EXECUTABLE" | tail -n +2 | awk '{print $1}' | \
  awk '$0 !~ /^\/System\// && $0 !~ /^\/usr\/lib\//')"
if [[ -n "$NON_SYSTEM_LIBRARIES" ]]; then
  echo "安全检查失败：检测到非系统动态库"
  printf '%s\n' "$NON_SYSTEM_LIBRARIES"
  exit 1
fi

SECRET_PATHS="$(git -C "$PROJECT_DIR" grep -l -I -E \
  '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{24,}|-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----)' \
  -- . ':!scripts/security-check.sh' 2>/dev/null || true)"
if [[ -n "$SECRET_PATHS" ]]; then
  echo "安全检查失败：以下文件疑似包含凭据"
  printf '%s\n' "$SECRET_PATHS"
  exit 1
fi

echo "安全检查通过：Hardened Runtime、系统动态库、最小权限和凭据扫描均正常"
