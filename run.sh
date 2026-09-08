#!/bin/bash
# Build and launch Lore (development build).
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

echo "▶︎ Regenerating Xcode project…"
xcodegen generate >/dev/null

echo "▶︎ Building Lore…"
xcodebuild \
  -project Lore.xcodeproj \
  -scheme Lore \
  -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS' \
  build

APP="build/Build/Products/Debug/Lore.app"
echo "▶︎ Launching $APP"
open "$APP"
