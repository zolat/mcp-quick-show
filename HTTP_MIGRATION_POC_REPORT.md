# HTTP MCP Migration — Phase 1 PoC Report

**Worktree:** `.claude/worktrees/feature+http-mcp-poc`
**Branch:** `worktree-feature+http-mcp-poc`
**Spec:** `HTTP_MIGRATION.md`

## Recommendation

**Go for Phase 2.** All three proof-points cleared (P1 strong, P2 strong, P3 informational-acceptable). The HTTP MCP server, libproc-based placement identity, and SDK-mediated session lifecycle work end-to-end against real Claude Code clients. One real bug surfaced during PoC (SIGPIPE on closed-SSE writes) was fixed inline. No fundamental blockers; the cost/benefit shape from the spec is preserved.

## What was built

7 commits on `worktree-feature+http-mcp-poc`, coexisting with the stdio sidecar (no destructive changes):

| Commit | What landed |
|---|---|
| `2cf422e` | `ROADMAP.md` Phase H1 pointer |
| `d681138` | `PeerPidResolver.swift` + `QUICKSHOW_TEST_PEER_PID=1` smoke |
| `600753f` | `modelcontextprotocol/swift-sdk` 0.12.1 via SPM in `project.yml` |
| `3f18f8e` | `MCPHTTPServer` + `MCPHTTPParser` — BSD-socket accept loop + HTTP/1.1 framing, gated on `QUICKSHOW_MCP_HTTP=1` |
| `d65efd3` | `MCPSessionRouter` — per-`Mcp-Session-Id` `StatefulHTTPServerTransport` dispatch |
| `6d6c0a8` | `MCPToolHandlers` — `show_html` reusing `SessionManager.upsert(...)` |
| `c0a2ffc` | P3 delayed `server.notify(...)` + `SO_NOSIGPIPE` on accepted sockets |

Files added (worktree-rooted): `QuickShow/Sources/Space/PeerPidResolver.swift`, `QuickShow/Sources/MCP/{MCPHTTPServer,MCPHTTPParser,MCPSessionRouter,MCPToolHandlers}.swift`. `project.yml` gained one `packages:` block. `AppDelegate.swift` gained `startMCPHTTPServerIfEnabled()` + `runPeerPidSmoke()` env-gated hooks. Existing stdio sidecar untouched; `plugin/.mcp.json` untouched.

Total new code: ~600 lines Swift. ~700 lines of MCP protocol/JSON-RPC/SSE plumbing avoided by using the SDK.

## P1 — libproc PID resolution

**Result: PASS, sub-millisecond walk.**

`PeerPidResolver.resolve(fd:)` calls `getpeername(fd)` to extract the client's ephemeral port, then walks `proc_listpids` → `proc_pidinfo(PROC_PIDLISTFDS)` → `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` against every PID on the system to find the matching TCP socket. Same kernel API path `lsof -i` uses. No entitlements required for same-user processes.

**Empirical observations (NSLog `QuickShow: PeerPidResolver` prefix):**

| Scenario | Resolved PID | Walk time |
|---|---|---|
| Direct `curl` from shell | matches `$!` after backgrounded curl | 0.12 ms |
| `bash -c "curl …"` (forked worker) | matches the curl PID (grandchild of test shell) | 0.07 ms |
| Real Claude (Claude Code's HTTP MCP client) | matches Claude's PID (one resolved per accept; many accepts per session) | 0.03–0.38 ms |
| Two parallel real Claudes | each connection resolved to its own Claude PID; no cross-attribution | <0.4 ms |

Well under the 100 ms threshold flagged in the spec; no need for per-session caching. Lands in main repo regardless of Phase 2 decision — useful on its own.

## P2 — Claude Code's HTTP MCP client + parallel-Claude isolation

**Result: PASS for both sub-criteria.**

Single Claude (`claude --print --mcp-config <throwaway.json> --strict-mcp-config --allowedTools mcp__quickshow-http__show_html`):

- Initialize handshake completes with `MCP-Session-Id` returned in response header.
- Claude opens the standalone SSE `GET /mcp` for server push.
- `tools/list` returns `show_html`.
- `tools/call show_html` lands → `SessionManager.upsert(...)` → HUD renders, screenshot returned as base64 image content block, `SpaceResolver` places the HUD via the libproc-resolved Claude PID.
- DELETE not exercised by Claude (relies on Phase 2 cleanup story).

Two parallel Claudes (`(claude …) & (claude …) &`):

| Claude | Process PID | Assigned `Mcp-Session-Id` | SpaceResolver `parent_pid` |
|---|---|---|---|
| A | 42447 | `67A0CA94-…` | 42447 |
| B | 42448 | `A4EFDC0B-…` | 42448 |

Distinct sessions, distinct PIDs, distinct Space placements. No cross-talk — each session's tool calls route to its own `Server` actor + `StatefulHTTPServerTransport`. Verified across ~6 separate runs.

(Note: on one early parallel run, Claude B reported "no `show_html` available" despite the server's `tools/list` returning it cleanly — likely a haiku-side model flake, not server-side. Repro with a clearer prompt succeeded.)

## P3 — Server-initiated push notifications

**Result: case (b) — acceptable.** Wire push works; real Claude doesn't surface it.

`MCPToolHandlers.firePushTest` schedules a `Task.detached` 5s after `show_html` returns and calls `server.notify(...)` with a `LogMessageNotification` (method `notifications/message`).

| Surface | Outcome |
|---|---|
| `server.notify(...)` succeeds | Logged "P3 push SENT" on every show_html call |
| Wire delivery via SSE GET | Confirmed via raw `curl -N` parallel session — frame arrives as `event: message\ndata: {"jsonrpc":"2.0","method":"notifications/message",…}` |
| SDK behavior when SSE GET not open | `notify()` returns cleanly (event likely queued to SDK's internal event store); no crash |
| Real Claude's `stream-json` output | Zero references to `notifications/message`, `delayed_push_p3`, or `quickshow.poc` across one-shot, multi-tool, and `Bash(sleep 8)`-holdopen runs |

Spec mapping: **case (b)** — "Notification arrives but isn't surfaced to Claude usefully." Phase 2 keeps `tail -F events.ndjson` + `Monitor` for markup/panel event channels exactly as today; HTTP migration loses nothing relative to current state.

### Real bug found during P3 development

Writing to a closed SSE FD raised SIGPIPE and reliably crashed the app whenever Claude exited inside the 5s push window. Fixed by setting `SO_NOSIGPIPE` on each accepted socket (`MCPHTTPServer.acceptOne`). Writes to closed peers now return EPIPE only; our `writeAll` already handles that. This would have been a Phase 2 production bug — surfacing it during the PoC is exactly the point.

## Other findings worth flagging for Phase 2

- **SDK fits the BSD-socket adapter cleanly.** The `StatefulHTTPServerTransport` is framework-agnostic (takes `HTTPRequest` values, returns `HTTPResponse` enum cases). Our adapter is ~140 lines for the listener + ~200 lines for the HTTP/1.1 parser + SSE pump. The conformance test's NIO-based `HTTPApp.swift` was a useful reference but is not a dependency; we link only the `MCP` library product. Transitive footprint: swift-system, swift-log, eventsource (NIO is resolved but not linked into our binary).
- **`SWIFT_STRICT_CONCURRENCY: complete` is OK.** No actor-isolation violations needed `@unchecked Sendable` shims. `MCPSessionRouter` is `@MainActor`; the SDK's `Server`/`StatefulHTTPServerTransport` are actors. Per-connection serve loops run as detached Tasks and hop to MainActor / SDK actors via `await`.
- **Build-time SourceKit lies persistently** about `import MCP` and same-module Swift types, exactly as `CLAUDE.md` warns. Trust `xcodebuild` as the oracle; the build is clean.
- **Lifecycle gap.** Sessions today are created on initialize, never timed out, and only dropped on explicit DELETE (which Claude doesn't send). For Phase 2: add the cleanup loop from the SDK's `HTTPApp.swift` (sessions older than N minutes since `lastAccessedAt` get torn down).
- **`tools/list` requires explicit registration.** The SDK does not auto-handle `tools/list`; we register it alongside `tools/call` in `MCPToolHandlers.register`. Easy, just a gotcha worth knowing for Phase 2 when more tools land.
- **JSON-RPC initialize peek.** The SDK's `JSONRPCMessageKind` is `package`-scoped, so our router does a 4-line JSON peek to decide "is this an initialize?" before creating a session. Trivial; reproduced verbatim from the conformance test's pattern.
- **`group` semantics unchanged in Phase 1.** Phase 1 keeps `group` as today's optional tab-grouping field, since promoting it to the canonical content namespace is destructive to the existing sidecar's wire shape. Phase 2 step 2 still owns that promotion + the `MarkupPaths` reroot.
- **End-user impact: zero.** `plugin/.mcp.json` still points at the stdio sidecar. `QUICKSHOW_MCP_HTTP=1` opt-in gate keeps the HTTP server off by default. The DMG build path is unchanged.

## Phase 2 readiness checklist (from spec §"Phase 2 — Full migration")

- [x] HTTP transport works in Claude Code's MCP client
- [x] SDK + BSD-socket adapter pattern proven
- [x] libproc placement-PID derivation proven and fast
- [x] Parallel-Claude isolation proven (per-session Server + transport, distinct PIDs)
- [x] `SessionManager.upsert(...)` reuse proven — Phase 2 doesn't need to rewrite the renderer/HUD/Space pipeline, only re-key it from `sessionId` to `group`
- [ ] Session timeout/cleanup loop (Phase 2 task; SDK conformance test has the pattern)
- [ ] Migration of remaining tools (markdown, svg, mermaid, image, url, enable_markup_events, get_markup, enable_panel_events) — same pattern as `show_html`
- [ ] `group`-as-canonical-namespace refactor across `MarkupPaths`, `events.ndjson`, `set_session_flag` → `set_group_flag`
- [ ] Switch `plugin/.mcp.json` to HTTP endpoint + login-item UX

## Reproduction recipe

```sh
# In the worktree:
xcodegen generate
xcodebuild -scheme QuickShow -configuration Debug build
APP=$(xcodebuild -showBuildSettings -scheme QuickShow 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR = / {print $2}')

# Run with HTTP server enabled, alt control socket so it doesn't fight
# the installed QuickShow.app:
QUICKSHOW_MCP_HTTP=1 \
QUICKSHOW_MCP_PORT=7891 \
QUICKSHOW_SOCKET_PATH=/tmp/qs-poc.sock \
  "$APP/QuickShow.app/Contents/MacOS/QuickShow" &

# Throwaway MCP config:
echo '{"mcpServers":{"quickshow-http":{"type":"http","url":"http://127.0.0.1:7891/mcp"}}}' > /tmp/poc-mcp.json

# Drive a single show_html via real Claude:
claude --print --mcp-config /tmp/poc-mcp.json --strict-mcp-config \
  --allowedTools "mcp__quickshow-http__show_html" --model haiku \
  "Call show_html (quickshow-http) name='demo', group='poc', \
   content='<html><body>hi</body></html>', return_screenshot=true. Then DONE."

# P1 standalone smoke (libproc only):
QUICKSHOW_TEST_PEER_PID=1 \
  "$APP/QuickShow.app/Contents/MacOS/QuickShow" &
# (See port in NSLog 'TEST_PEER_PID listening port=…', then:)
curl http://127.0.0.1:<port>/
```

## Stop point

Per `HTTP_MIGRATION.md` line 431 — **stopping here.** Phase 2 awaits explicit user approval.
