#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CPUMonitor"
BUILD_DIR="$DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"

echo "Compiling..."
swiftc -O \
    -o "$MACOS_DIR/$APP_NAME" \
    "$DIR/main.swift" \
    -framework AppKit \
    -framework UserNotifications

cp "$DIR/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc sign so notifications and menu bar work correctly
codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "Installing to /Applications..."
pkill -x "$APP_NAME" 2>/dev/null || true
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
open "/Applications/$APP_NAME.app"

echo ""
echo "Built:   $APP_BUNDLE"
echo "Installed & launched: /Applications/$APP_NAME.app"
