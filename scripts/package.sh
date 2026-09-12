#!/bin/bash
# Build a Release Lore.app and package it into a distributable .dmg.
#
# The app is ad-hoc signed (no Apple Developer ID), so downloaders must clear
# Gatekeeper on first launch — see the "Download" section of README.md.
#
# Usage: ./scripts/package.sh
# Output: dist/Lore-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Lore"
BUILD_DIR="build"
DIST_DIR="dist"
STAGING="$DIST_DIR/dmg-staging"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

echo "▶︎ Regenerating Xcode project…"
xcodegen generate >/dev/null

echo "▶︎ Building $APP_NAME (Release)…"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS' \
  build >/dev/null

[ -d "$APP_PATH" ] || { echo "✗ Build did not produce $APP_PATH"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "▶︎ Staging disk image contents…"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install target

echo "▶︎ Creating $DMG_PATH…"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING"
echo "✓ Done: $DMG_PATH"
