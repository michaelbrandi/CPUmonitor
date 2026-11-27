#!/bin/bash
# Install or update the CPUMonitor menu-bar app from a GitHub release.
# No Xcode / Swift toolchain needed — it just swaps the .app bundle.
#
#   ./update.sh                 # newest build
#   ./update.sh build-1a2b3c4   # a specific release tag
#
# One-liner on another Mac:
#   curl -fsSL https://raw.githubusercontent.com/michaelbrandi/CPUmonitor/master/macos-native/update.sh | bash
#
# The "Run On Login" setting lives in ~/Library/LaunchAgents and survives.

set -euo pipefail

REPO="michaelbrandi/CPUmonitor"
APP_NAME="CPUMonitor"
DEST="/Applications/$APP_NAME.app"
TAG="${1:-}"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: this script is for macOS" >&2
    exit 1
fi

if [ -z "$TAG" ] || [ "$TAG" = "latest" ]; then
    URL="https://github.com/$REPO/releases/latest/download/$APP_NAME-macOS.zip"
else
    URL="https://github.com/$REPO/releases/download/$TAG/$APP_NAME-macOS.zip"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $APP_NAME"
echo "  $URL"
curl -fsSL "$URL" -o "$TMP/app.zip"

echo "Unpacking"
unzip -q "$TMP/app.zip" -d "$TMP"
if [ ! -d "$TMP/$APP_NAME.app" ]; then
    echo "error: $APP_NAME.app not found in the archive" >&2
    exit 1
fi

if [ ! -w /Applications ]; then
    echo "error: /Applications is not writable by $(whoami); re-run with sudo" >&2
    exit 1
fi

echo "Stopping running copy"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "Installing to $DEST"
rm -rf "$DEST"
cp -R "$TMP/$APP_NAME.app" "$DEST"
# A browser-downloaded archive carries the quarantine flag; a curl'd one does not.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$DEST/Contents/MacOS/$APP_NAME" 2>/dev/null || true)"
    case "$archs" in
        ""|*"$(uname -m)"*) ;;
        *) echo "warning: build is for [$archs] but this Mac is $(uname -m)" >&2 ;;
    esac
fi

echo "Launching"
open "$DEST" 2>/dev/null \
    || { sleep 1; open "$DEST" 2>/dev/null; } \
    || echo "warning: could not launch — open $DEST manually"

echo "Done. Click the menu-bar icon; it offers Run On Login if you want it."
