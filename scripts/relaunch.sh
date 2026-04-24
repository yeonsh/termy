#!/usr/bin/env bash
# Kill any running termy, rebuild Debug, relaunch. Tap Dock to bounce the icon
# cache after `touch` so the new icon / binary show up immediately.
#
# Usage: scripts/relaunch.sh [--release]
set -euo pipefail

CONFIG="Debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="Release"
fi

cd "$(dirname "$0")/.."

pkill -x termy 2>/dev/null || true

xcodebuild \
    -project termy.xcodeproj \
    -scheme termy \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    build \
    | tail -4

APP_PATH="$(xcodebuild \
    -project termy.xcodeproj \
    -scheme termy \
    -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ { print $2; exit }')/termy.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "relaunch.sh: built app not found at $APP_PATH" >&2
    exit 1
fi

touch "$APP_PATH"
open "$APP_PATH"
echo "relaunched: $APP_PATH"
