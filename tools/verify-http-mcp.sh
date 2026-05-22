#!/usr/bin/env bash
# Comprehensive HTTP MCP verifier. Drives multi-tool, multi-session
# scenarios against a running QuickShow.app. Successor to the
# sidecar's verify-phase*.ts + verify-tab-groups.ts + verify-url.ts +
# verify-panel-events.ts scripts (all deleted in 2.4 along with the
# sidecar).
#
# Usage:
#   tools/verify-http-mcp.sh         — build + run all checks
#   tools/verify-http-mcp.sh skip    — skip build (use existing .app)
#
# Each check prints `✓` or `✘` + a one-line summary. Exits non-zero
# on any failure.

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
  > /tmp/quickshow-verify.log 2>&1 &
sleep 3

FAILED=0
cleanup() {
  pkill -f "QuickShow.app/Contents/MacOS/QuickShow" 2>/dev/null || true
  exit $FAILED
}
trap cleanup EXIT

# Helper — initialize a fresh MCP session, return its sid.
init_session() {
  local tag="$1"
  curl -sf http://127.0.0.1:7890/mcp -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"$tag\",\"version\":\"1.0\"}}}" \
    -D "/tmp/qs-verify-$tag.txt" -o /dev/null
  local sid
  sid=$(grep -i 'mcp-session-id:' "/tmp/qs-verify-$tag.txt" | awk '{print $2}' | tr -d '\r')
  curl -sf http://127.0.0.1:7890/mcp -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' > /dev/null
  echo "$sid"
}

# Helper — call a tool, extract text + isError.
call_tool() {
  local sid="$1" payload="$2"
  curl -sf http://127.0.0.1:7890/mcp -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: $sid" \
    -d "$payload" | sed -n 's/^data: //p' | tail -1
}

assert_ok() {
  local label="$1" resp="$2"
  local err
  err=$(echo "$resp" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("result",{}).get("isError"))' 2>/dev/null || echo "PARSE-ERR")
  if [[ "$err" == "None" ]]; then
    echo "✓ $label"
  else
    echo "✘ $label — isError=$err"
    echo "$resp" | head -c 200
    FAILED=1
  fi
}

# ----- 1. show_url -----
SID=$(init_session url)
RESP=$(call_tool "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_url","arguments":{"name":"verify-url","url":"https://example.com","group":"verify-url-grp","width":800,"return_screenshot":false}}}')
assert_ok "show_url (https://example.com → 800pt viewport, group=verify-url-grp)" "$RESP"

# ----- 2. enable_panel_events + emit -----
# Pick up the group's events.ndjson path from the response.
SID=$(init_session pe)
RESP=$(call_tool "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"enable_panel_events","arguments":{"group":"verify-pe-grp"}}}')
TEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"]["content"][0]["text"])')
LOG=$(echo "$TEXT" | grep -E "^  command:" | sed -E 's/.*tail -n 0 -F (.*)`/\1/')
LOG_DIR=$(dirname "$LOG")
if [[ ! -d "$LOG_DIR" ]]; then
  echo "✘ enable_panel_events: events dir not created at $LOG_DIR"
  FAILED=1
else
  echo "✓ enable_panel_events (events dir at $LOG_DIR)"
fi
# Render an HTML page that emits on load + verify line appears.
HTML='<!doctype html><html><body><script>setTimeout(()=>window.quickshow.emit({verify:"on-load"}),300);</script></body></html>'
PAYLOAD=$(python3 -c "import json; print(json.dumps({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'show_html','arguments':{'name':'pe-html','content':'$HTML','group':'verify-pe-grp','return_screenshot':False}}}))")
call_tool "$SID" "$PAYLOAD" > /dev/null
sleep 1
if grep -q '"verify":"on-load"' "$LOG"; then
  echo "✓ panel_event emit reached events.ndjson"
else
  echo "✘ panel_event emit not found in $LOG"
  tail -3 "$LOG" 2>/dev/null
  FAILED=1
fi

# ----- 3. Multi-session same-group → tab-group -----
SID_A=$(init_session ta)
SID_B=$(init_session tb)
call_tool "$SID_A" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_html","arguments":{"name":"hero-a","content":"<html><body>A</body></html>","group":"verify-collab","return_screenshot":false}}}' > /dev/null
RESP=$(call_tool "$SID_B" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_html","arguments":{"name":"hero-b","content":"<html><body>B</body></html>","group":"verify-collab","return_screenshot":false}}}')
assert_ok "two MCP sessions writing to group=verify-collab (B's call succeeds)" "$RESP"
# Verify only ONE Space placement happened (first writer wins).
# Coarser signal: count "SpaceResolver — moved HUD" lines.
# (Two distinct groups each get one placement; same group only gets
# one. Run after a single batch to make this meaningful.)
PLACES=$(grep -c "SpaceResolver — moved HUD" /tmp/quickshow-verify.log 2>/dev/null || echo 0)
echo "✓ verify-collab: $PLACES SpaceResolver placement(s) so far (logged for inspection)"

# ----- 4. enable_markup_events + /markup-events stream attaches -----
SID=$(init_session mk)
RESP=$(call_tool "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"enable_markup_events","arguments":{"group":"verify-mk-grp"}}}')
assert_ok "enable_markup_events armed for verify-mk-grp" "$RESP"
# Tap the SSE stream briefly. The endpoint writes headers
# immediately on connect (subscriber registered), so a 2s probe
# is enough — the 10s heartbeat would cost real wall-time. Verify
# server-side subscription log lands.
curl -sN -m 2 -H "Mcp-Session-Id: verify-mk-grp" \
  http://127.0.0.1:7890/markup-events > /tmp/qs-verify-sse.txt 2>&1 || true
if grep -q "markup-events subscribed group=verify-mk-grp" /tmp/quickshow-verify.log; then
  echo "✓ /markup-events: subscriber registered for verify-mk-grp"
else
  echo "✘ /markup-events: subscription not registered"
  grep "markup-events" /tmp/quickshow-verify.log | tail -3
  FAILED=1
fi

# ----- 5. Liveness: DELETE → orphan-grace timer -----
SID=$(init_session lv)
call_tool "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_html","arguments":{"name":"x","content":"<html><body>orphan-test</body></html>","group":"verify-orphan-grp","return_screenshot":false}}}' > /dev/null
# DELETE: -m 5 to fail fast on any wire weirdness rather than hang.
curl -s -m 5 http://127.0.0.1:7890/mcp -X DELETE -H "Mcp-Session-Id: $SID" -o /dev/null || true
sleep 0.5
if grep -q "MCP session $SID dropped — starting orphan grace for group verify-orphan-grp" /tmp/quickshow-verify.log; then
  echo "✓ DELETE → orphan grace started for verify-orphan-grp"
else
  echo "✘ DELETE did not trigger orphan-grace wire-up"
  grep "orphan\|MCP session" /tmp/quickshow-verify.log | tail -5
  FAILED=1
fi

if [[ $FAILED -eq 0 ]]; then
  echo ""
  echo "All checks passed."
fi
