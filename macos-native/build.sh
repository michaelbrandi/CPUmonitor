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
    -framework AppKit

cp "$DIR/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc sign so notifications and menu bar work correctly
codesign --force --sign - "$APP_BUNDLE"

# CI only needs the bundle; installing and launching on a runner is pointless.
if [ "${1:-}" = "--no-install" ]; then
    echo ""
    echo "Built: $APP_BUNDLE (not installed)"
    exit 0
fi

echo ""
echo "Installing to /Applications..."
pkill -x "$APP_NAME" 2>/dev/null || true
# cp -R into an existing bundle nests it instead of replacing it, which leaves
# the old binary running from /Applications. Remove first.
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
# LaunchServices sometimes races the bundle replacement and returns -600
# (procNotFound); retry once rather than aborting the build.
open "/Applications/$APP_NAME.app" 2>/dev/null \
    || { sleep 1; open "/Applications/$APP_NAME.app" 2>/dev/null; } \
    || echo "Warning: could not launch automatically — open it from /Applications."

echo ""
echo "Built:   $APP_BUNDLE"
echo "Installed & launched: /Applications/$APP_NAME.app"
