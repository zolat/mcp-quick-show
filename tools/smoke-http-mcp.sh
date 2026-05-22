#!/usr/bin/env bash
# Quick smoke for the embedded HTTP MCP server. Launches the freshly
# built app, drives initialize → tools/list → show_html, and dumps the
# happy/sad paths. Used after each 2.2 refactor chunk so the build +
# wire end-to-end is verified in <10s.
#
# Usage:
#   tools/smoke-http-mcp.sh         — build + run smoke
#   tools/smoke-http-mcp.sh skip    — skip build (use existing .app)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

if [[ "${1:-}" != "skip" ]]; then
  xcodebuild -scheme QuickShow -configuration Debug build 2>&1 | grep -E "BUILD |error:" | tail -3
fi

APP=$(xcodebuild -showBuildSettings -scheme QuickShow 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR = / {print $2}')

pkill -f "QuickShow.app/Contents/MacOS/QuickShow" 2>/dev/null || true
sleep 1

"$APP/QuickShow.app/Contents/MacOS/QuickShow" \
  > /tmp/quickshow-smoke.log 2>&1 &
APP_PID=$!
sleep 3

cleanup() {
  pkill -f "QuickShow.app/Contents/MacOS/QuickShow" 2>/dev/null || true
}
trap cleanup EXIT

# Initialize → grab session id.
curl -sf http://127.0.0.1:7890/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1.0"}}}' \
  -D /tmp/qs-smoke-headers.txt -o /tmp/qs-smoke-init.txt
SID=$(grep -i 'mcp-session-id:' /tmp/qs-smoke-headers.txt | awk '{print $2}' | tr -d '\r')
if [[ -z "$SID" ]]; then
  echo "✘ initialize: no Mcp-Session-Id header"
  exit 1
fi
echo "✓ initialize ok (sid=$SID)"

curl -sf http://127.0.0.1:7890/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' > /dev/null

# tools/list — expect 10 tools.
TOOLS=$(curl -sf http://127.0.0.1:7890/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | sed -n 's/^data: //p' | python3 -c 'import sys,json; d=json.loads(sys.stdin.read().splitlines()[-1]); print("\n".join(t["name"] for t in d["result"]["tools"]))')
COUNT=$(echo "$TOOLS" | wc -l | tr -d ' ')
echo "✓ tools/list ($COUNT tools)"
echo "$TOOLS" | sed 's/^/  - /'

# show_html happy path.
HTML='<!doctype html><html><body><h1 style="font-family:sans-serif">smoke</h1></body></html>'
PAYLOAD=$(python3 -c "import json; print(json.dumps({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'show_html','arguments':{'name':'smoke','content':'$HTML','return_screenshot':False}}}))")
RESP=$(curl -sf http://127.0.0.1:7890/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" \
  -d "$PAYLOAD" | sed -n 's/^data: //p' | tail -1)
TEXT=$(echo "$RESP" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("result",{}).get("content",[{}])[0].get("text","NO-TEXT"))')
ERR=$(echo "$RESP" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("result",{}).get("isError"))')
echo "✓ show_html: isError=$ERR — $TEXT"
