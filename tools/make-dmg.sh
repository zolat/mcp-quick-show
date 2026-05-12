#!/usr/bin/env bash
# Build a Release configuration of QuickShow.app and wrap it in a DMG.
# Output: dist/QuickShow-<version>.dmg
#
# Ad-hoc signed (matches project.yml). Developer-ID + notarization is
# deferred to a separate v0.1 distribution-readiness track.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml | tr -d '"')"
if [ -z "$VERSION" ]; then
    echo "error: could not read MARKETING_VERSION from project.yml" >&2
    exit 1
fi
echo "Building QuickShow v${VERSION}…"

# Build Release.
xcodebuild -scheme QuickShow -configuration Release build -quiet

BUILD_DIR="$(xcodebuild -showBuildSettings -scheme QuickShow -configuration Release 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR = / {print $2}')"
APP_PATH="${BUILD_DIR}/QuickShow.app"

if [ ! -d "$APP_PATH" ]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
fi

DIST_DIR="${ROOT}/dist"
STAGE_DIR="${DIST_DIR}/stage"
DMG_PATH="${DIST_DIR}/QuickShow-${VERSION}.dmg"

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
# Convenience symlink so users can drag the .app to /Applications.
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "QuickShow ${VERSION}" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGE_DIR"

echo ""
echo "✓ DMG built at: $DMG_PATH"
echo ""
echo "Bundle layout:"
echo "  $APP_PATH/Contents/MacOS/QuickShow"
echo "  $APP_PATH/Contents/Resources/mcp-quick-show     ← bundled sidecar"
echo "  $APP_PATH/Contents/Resources/templates/         ← renderer HTML"
echo "  $APP_PATH/Contents/Resources/libs/              ← marked/purify/mermaid"
echo ""
echo "Install: drag QuickShow.app into /Applications, launch once, then"
echo "click 'Connect to Claude Code' in Preferences to register the MCP"
echo "server. Restart Claude Code afterwards."
