#!/usr/bin/env bash
# Build the mcp-quick-show sidecar with `bun build --compile` and copy
# it into the QuickShow.app bundle's Resources directory. Invoked from
# project.yml as a postCompileScripts phase on the QuickShow target.
#
# - Release configuration → universal compiled binary.
# - Debug configuration   → skip the compile (sidecar runs from source
#                           via `bun run sidecar/src/index.ts` during
#                           dev). This keeps Debug builds fast.
#
# Xcode build phases run with a sparse PATH; we probe common bun
# locations rather than assuming it's on PATH.

set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run this from an Xcode build phase)}"
: "${CONFIGURATION:?CONFIGURATION must be set}"

# Debug builds skip bundling — sidecar runs from source for fast iteration.
if [ "$CONFIGURATION" != "Release" ]; then
    echo "build-sidecar: $CONFIGURATION build — skipping bundle (sidecar runs from source)"
    exit 0
fi

: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set}"
: "${PRODUCT_NAME:?PRODUCT_NAME must be set}"

SIDECAR_DIR="${SRCROOT}/sidecar"
OUT_DIR="${TARGET_BUILD_DIR}/${PRODUCT_NAME}.app/Contents/Resources"
OUT_BIN="${OUT_DIR}/mcp-quick-show"

if [ ! -f "${SIDECAR_DIR}/package.json" ]; then
    echo "build-sidecar: sidecar/ not yet present — skipping"
    exit 0
fi

BUN="${BUN:-}"
if [ -z "$BUN" ]; then
    for candidate in \
        "$HOME/.bun/bin/bun" \
        "/opt/homebrew/bin/bun" \
        "/usr/local/bin/bun"; do
        if [ -x "$candidate" ]; then
            BUN="$candidate"
            break
        fi
    done
fi

if [ -z "$BUN" ] || [ ! -x "$BUN" ]; then
    echo "error: bun not found. Install via 'brew install oven-sh/bun/bun' or https://bun.sh." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
cd "$SIDECAR_DIR"

# Ensure deps are present (no-op if already installed).
"$BUN" install --frozen-lockfile 2>/dev/null || "$BUN" install

# Compile to a standalone universal binary.
"$BUN" build --compile --minify --sourcemap --target=bun-darwin-arm64 \
    --outfile "$OUT_BIN" \
    ./src/index.ts

echo "mcp-quick-show bundled at $OUT_BIN ($(file -b "$OUT_BIN"))"
