#!/usr/bin/env bash
# Build the mcp-quick-show sidecar with `bun build --compile` and drop
# the standalone binary into `plugin/bin/mcp-quick-show` so the Claude
# Code plugin can reference it via `${CLAUDE_PLUGIN_ROOT}/bin/...` in
# its `.mcp.json`.
#
# Parallel to `tools/build-sidecar.sh` (which drops the same binary
# inside QuickShow.app for Release builds). Both produce a bit-identical
# binary from the same source tree — running both keeps the plugin
# binary and the .app's bundled sidecar in lockstep.
#
# Run from anywhere; the script anchors itself to the repo root.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

SIDECAR_DIR="$REPO_ROOT/sidecar"
OUT_DIR="$REPO_ROOT/plugin/bin"
OUT_BIN="$OUT_DIR/mcp-quick-show"

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

# Compile to a standalone macOS arm64 binary. Matches the target of
# tools/build-sidecar.sh so the two outputs are bit-identical.
"$BUN" build --compile --minify --sourcemap --target=bun-darwin-arm64 \
    --outfile "$OUT_BIN" \
    ./src/index.ts

chmod +x "$OUT_BIN"

echo
echo "mcp-quick-show built at: $OUT_BIN"
echo "  $(file -b "$OUT_BIN")"
echo
echo "Install locally:"
echo "  mkdir -p ~/.claude/plugins/cache/local/quickshow"
echo "  ln -sfn $REPO_ROOT/plugin ~/.claude/plugins/cache/local/quickshow/dev"
echo "Then restart Claude Code (or /clear)."
