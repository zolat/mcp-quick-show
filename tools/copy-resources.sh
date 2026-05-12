#!/usr/bin/env bash
# Copy QuickShow's bundled HTML / CSS / JS templates into the .app
# bundle's Resources directory, preserving subdirectory structure
# (templates/, libs/). Run from xcodegen's postCompileScripts.

set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from an Xcode build phase)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set}"
: "${PRODUCT_NAME:?PRODUCT_NAME must be set}"

SRC_DIR="${SRCROOT}/QuickShow/Resources"
DST_DIR="${TARGET_BUILD_DIR}/${PRODUCT_NAME}.app/Contents/Resources"

if [ ! -d "$SRC_DIR" ]; then
    echo "copy-resources: source dir '$SRC_DIR' does not exist — skipping"
    exit 0
fi

mkdir -p "$DST_DIR"

# rsync preserves directory structure and is idempotent under Xcode's
# incremental builds (skips unchanged files).
rsync -a --delete \
    --exclude='.DS_Store' \
    "$SRC_DIR/" "$DST_DIR/"

echo "copy-resources: synced $SRC_DIR → $DST_DIR"
