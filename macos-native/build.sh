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
echo "Built:  $APP_BUNDLE"
echo "Run:    open $APP_BUNDLE"
